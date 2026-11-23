# frozen_string_literal: true

module RedmineTeamPlanning
  # Planung einer Person, gesehen von einem Betrachter.
  #
  # Orte eines Tickets im Plan:
  #   "backlog"     offen, der Person zugewiesen, nirgends eingeplant
  #   "pool"        offen, niemandem zugewiesen (nur als Quelle)
  #   "standing"    Dauerthema, läuft jede Woche mit
  #   "later"       vorgemerkt ohne Zeitraum
  #   "YYYY-MM-DD"  in dem offenen Zeitraum, der an diesem Tag beginnt
  #
  # Der laufende Zeitraum ist der früheste nicht abgeschlossene; es folgen
  # drei weitere mit der eingestellten Länge.
  class Planner
    class Error < StandardError; end

    FUTURE_PERIODS = 3

    attr_reader :user, :viewer, :today

    def initialize(user, viewer = User.current, today: nil)
      @user = user
      @viewer = viewer
      @today = today || viewer.today
    end

    def editable?
      Access.edit?(viewer, user)
    end

    def own?
      viewer == user
    end

    def setting
      @setting ||= TeamPlanningUserSetting.for(user)
    end

    def weeks
      setting.weeks
    end

    def limit
      setting.item_limit
    end

    # --- Zeiträume ---------------------------------------------------------

    def self.monday(date)
      date - (date.cwday - 1)
    end

    def current_period
      @current_period ||= user_periods.open.order(:starts_on).first ||
                          TeamPlanningPeriod.create!(user: user, starts_on: self.class.monday(today), weeks: weeks)
    end

    # Laufender und folgende Zeiträume; noch nicht angelegte bleiben ungespeichert
    def periods
      @periods ||= begin
        list = [current_period]
        start = current_period.ends_on + 1
        FUTURE_PERIODS.times do
          period = user_periods.open.find_by(starts_on: start) ||
                   TeamPlanningPeriod.new(user: user, starts_on: start, weeks: weeks)
          list << period
          start = period.ends_on + 1
        end
        list
      end
    end

    def period_for(key)
      date = key.is_a?(Date) ? key : Date.iso8601(key.to_s)
      period = periods.find { |p| p.starts_on == date }
      raise Error, l(:error_team_planning_unknown_period) unless period

      period.save! if period.new_record?
      period
    rescue Date::Error
      raise Error, l(:error_team_planning_unknown_period)
    end

    def past_period
      user_periods.closed.order(starts_on: :desc).first
    end

    def effective_limit(period)
      days = period.workdays
      absent = period.absence_days.clamp(0, days)
      return 0 if absent >= days

      [(limit * (days - absent).to_f / days).round, 1].max
    end

    # --- Inhalte -----------------------------------------------------------

    def items(period)
      return [] if period.new_record?

      visible_only(period.items.includes(issue: %i[status project tracker priority assigned_to]).to_a)
    end

    # Tickets, die der Betrachter nicht sehen darf, erscheinen nur als Anzahl
    def hidden_count(period)
      return 0 if period.new_record?

      period.items.size - items(period).size
    end

    def standings
      visible_only(TeamPlanningStanding.where(user_id: user.id).includes(issue: %i[status project]).order(:position, :id)
        .to_a).reject { |s| s.issue.closed? }
    end

    def later_items
      visible_only(TeamPlanningLaterItem.where(user_id: user.id).includes(issue: %i[status project]).order(:position, :id)
        .to_a)
    end

    def backlog
      Issue.visible(viewer).open.where(assigned_to_id: user.id)
           .where.not(id: planned_issue_ids).where.not(status_id: done_status_ids)
           .includes(:status, :project, :priority).order(priority_id: :desc, id: :desc).limit(300).to_a
    end

    def pool
      Issue.visible(viewer).open.where(assigned_to_id: nil)
           .where(updated_on: Settings.pool_months.months.ago..)
           .where.not(status_id: done_status_ids)
           .includes(:status, :project, :priority).order(priority_id: :desc, updated_on: :desc).limit(300).to_a
    end

    def done?(item)
      item.done || done_status_ids.include?(item.issue.status_id)
    end

    def done_status_ids
      @done_status_ids ||= Settings.done_status_ids
    end

    # Wie oft wurde das Ticket bei dieser Person schon weitergeschoben?
    def carries(issue)
      carry_counts[issue.id].to_i
    end

    def counted_items(period)
      items(period)
    end

    # --- Stunden -----------------------------------------------------------

    def booked_hours(period)
      time_entries(period).sum(:hours).to_f
    end

    def booked_for(issue, period)
      time_entries(period).where(issue_id: issue.id).sum(:hours).to_f
    end

    # Gebucht im Zeitraum auf Tickets, die weder geplant noch Dauerthema sind
    def booked_outside(period)
      inside = items(period).map(&:issue_id) + standings.map(&:issue_id)
      time_entries(period).where.not(issue_id: inside).or(time_entries(period).where(issue_id: nil)).sum(:hours).to_f
    end

    def booked_by_day(period)
      time_entries(period).group(:spent_on).sum(:hours).transform_values(&:to_f)
    end

    # --- Wo steht ein Ticket? ---------------------------------------------

    def location(issue)
      return 'standing' if TeamPlanningStanding.exists?(user_id: user.id, issue_id: issue.id)
      return 'later' if TeamPlanningLaterItem.exists?(user_id: user.id, issue_id: issue.id)

      item = open_items.find_by(issue_id: issue.id)
      return item.period.starts_on.iso8601 if item

      issue.assigned_to_id.nil? ? 'pool' : 'backlog'
    end

    def position_in(issue, location)
      case location
      when 'standing' then TeamPlanningStanding.where(user_id: user.id).order(:position, :id).pluck(:issue_id).index(issue.id)
      when 'later' then TeamPlanningLaterItem.where(user_id: user.id).order(:position, :id).pluck(:issue_id).index(issue.id)
      when /\A\d{4}-\d{2}-\d{2}\z/ then period_for(location).items.pluck(:issue_id).index(issue.id)
      end
    end

    # --- Änderungen --------------------------------------------------------

    # Verschiebt ein Ticket. Aus dem Pool wird es der Person zugewiesen.
    # Gibt zurück, wie es rückgängig zu machen ist.
    def move(issue, to:, position: nil)
      ensure_editable!
      from = location(issue)
      from_position = position_in(issue, from)
      assigned = false
      kept = nil

      TeamPlanningItem.transaction do
        if issue.assigned_to_id.nil? && to != 'pool'
          assign!(issue, user)
          assigned = true
        end
        kept = remove_from_plan(issue)
        place(issue, to, position, kept, from)
      end
      reset
      { from: from, position: from_position, assigned: assigned }
    end

    # Legt eine Aufgabe an und plant sie gleich ein
    def create_issue(subject:, project:, to:)
      ensure_editable!
      issue = Issue.new(project: project, author: viewer, subject: subject.to_s.strip,
                        tracker: Settings.tracker_for(project), priority: IssuePriority.default)
      issue.assigned_to = user unless to == 'pool'
      raise Error, l(:error_team_planning_not_allowed) unless viewer.allowed_to?(:add_issues, project)

      Issue.transaction do
        unless issue.save
          raise Error, issue.errors.full_messages.to_sentence
        end

        place(issue, to, nil, nil, 'backlog') unless %w[pool backlog].include?(to)
      end
      reset
      issue
    end

    def update_item(issue, attributes)
      ensure_editable!
      item = open_items.find_by(issue_id: issue.id)
      raise Error, l(:error_team_planning_not_planned) unless item

      previous = item.slice(:planned_hours, :kind, :until_on, :carry_ack).select { |key, _| attributes.key?(key.to_sym) || (key == 'until_on' && attributes.key?(:kind)) }
      item.planned_hours = attributes[:planned_hours].presence if attributes.key?(:planned_hours)
      item.carry_ack = attributes[:carry_ack].to_i if attributes.key?(:carry_ack)
      if attributes.key?(:kind)
        item.kind = attributes[:kind]
        item.until_on = item.long? ? attributes[:until_on].presence : nil
      end
      raise Error, item.errors.full_messages.to_sentence unless item.save

      reset
      previous
    end

    def set_absence(period_key, days)
      ensure_editable!
      period = period_for(period_key)
      previous = period.absence_days
      period.update!(absence_days: days.to_i.clamp(0, period.workdays))
      reset
      previous
    end

    def update_settings(weeks: nil, limit: nil)
      ensure_editable!
      TeamPlanningUserSetting.transaction do
        old_weeks = setting.weeks
        setting.weeks = weeks.to_i if weeks.present?
        setting.item_limit = limit.to_i if limit.present?
        raise Error, setting.errors.full_messages.to_sentence unless setting.save

        regroup_future_periods if setting.weeks != old_weeks
      end
      reset
    end

    # Aus dem Plan nehmen und die Zuweisung entfernen: zurück in den Pool
    def unassign(issue)
      ensure_editable!
      TeamPlanningItem.transaction do
        remove_from_plan(issue)
        assign!(issue, nil)
      end
      reset
    end

    def reset
      @periods = @current_period = @carry_counts = nil
      @open_items = nil
    end

    private

    def l(*args)
      ::I18n.t(*args)
    end

    def ensure_editable!
      raise Error, l(:error_team_planning_not_allowed) unless editable?
    end

    def user_periods
      TeamPlanningPeriod.where(user_id: user.id)
    end

    def open_items
      TeamPlanningItem.joins(:period).merge(user_periods.open).where(team_planning_periods: { user_id: user.id })
    end

    def planned_issue_ids
      open_items.pluck(:issue_id) +
        TeamPlanningStanding.where(user_id: user.id).pluck(:issue_id) +
        TeamPlanningLaterItem.where(user_id: user.id).pluck(:issue_id)
    end

    def carry_counts
      @carry_counts ||= TeamPlanningItem.joins(:period).where(team_planning_periods: { user_id: user.id },
                                                               result: 'carried').group(:issue_id).count
    end

    def visible_only(records)
      ids = Issue.visible(viewer).where(id: records.map(&:issue_id)).pluck(:id).to_set
      records.select { |record| ids.include?(record.issue_id) }
    end

    def time_entries(period)
      scope = TimeEntry.where(user_id: user.id, spent_on: period.starts_on..period.ends_on)
      own? ? scope : scope.merge(TimeEntry.visible(viewer))
    end

    # Entfernt das Ticket aus offenen Zeiträumen, Später und Dauerthemen.
    # Gibt die Eigenschaften des Plan-Eintrags zurück (Stunden, Langläufer).
    def remove_from_plan(issue)
      kept = nil
      open_items.where(issue_id: issue.id).find_each do |item|
        kept = item.slice(:kind, :until_on, :planned_hours, :origin, :carry_ack)
        item.destroy
      end
      TeamPlanningStanding.where(user_id: user.id, issue_id: issue.id).delete_all
      TeamPlanningLaterItem.where(user_id: user.id, issue_id: issue.id).delete_all
      kept
    end

    def place(issue, to, position, kept, from)
      case to
      when 'backlog', 'pool'
        nil
      when 'standing'
        insert(TeamPlanningStanding.where(user_id: user.id), TeamPlanningStanding.new(user: user, issue: issue), position)
      when 'later'
        insert(TeamPlanningLaterItem.where(user_id: user.id), TeamPlanningLaterItem.new(user: user, issue: issue), position)
      else
        period = period_for(to)
        item = TeamPlanningItem.new(period: period, issue: issue, **(kept || {}).symbolize_keys.except(:origin))
        item.origin = origin_for(period, from, kept)
        insert(period.items, item, position)
      end
    end

    # Ungeplant: kam in den laufenden Zeitraum, nachdem er begonnen hat
    def origin_for(period, from, kept)
      if period == current_period && current_period.starts_on < today && from != period.starts_on.iso8601
        'unplanned'
      elsif kept && kept['origin'] == 'carried'
        'carried'
      else
        'planned'
      end
    end

    def insert(scope, record, position)
      list = scope.order(:position, :id).to_a
      index = position.nil? ? list.size : position.to_i.clamp(0, list.size)
      list.insert(index, record)
      list.each_with_index do |entry, n|
        entry.position = n
        entry.save! if entry.new_record? || entry.position_changed?
      end
    end

    def assign!(issue, assignee)
      issue.init_journal(viewer)
      issue.safe_attributes = { 'assigned_to_id' => assignee&.id.to_s }
      if issue.assigned_to_id != assignee&.id
        raise Error, l(:error_team_planning_cannot_assign)
      end
      raise Error, issue.errors.full_messages.to_sentence unless issue.save
    end

    # Neue Länge: künftige Zeiträume neu einteilen, Tickets behalten ihre
    # Reihenfolge und landen im Zeitraum, in dem ihr alter Zeitraum begann
    def regroup_future_periods
      future = user_periods.open.where('starts_on > ?', current_period.starts_on).order(:starts_on).to_a
      moved = future.flat_map { |period| period.items.map { |item| [period.starts_on, item.attributes] } }
      future.each(&:destroy)
      reset
      moved.each do |starts_on, attributes|
        target = periods.drop(1).find { |p| p.include?(starts_on) }
        if target
          target.save! if target.new_record?
          TeamPlanningItem.create!(attributes.except('id', 'period_id', 'created_at', 'updated_at')
            .merge('period_id' => target.id, 'position' => target.items.count))
        else
          insert(TeamPlanningLaterItem.where(user_id: user.id),
                 TeamPlanningLaterItem.new(user: user, issue_id: attributes['issue_id']), nil)
        end
      end
    end
  end
end
