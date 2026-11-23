# frozen_string_literal: true

module RedmineTeamPlanning
  # Einstellungen des Plugins (Administration → Plugins → Team Planning)
  module Settings
    DEFAULTS = {
      # Status, die automatisch als erledigt zählen; leer: alle geschlossenen
      # plus "Resolved" und "For Billing", sofern vorhanden
      'done_status_ids' => [],
      # Abschluss-Aktionen beim Abhaken, Reihenfolge = Vorauswahl
      # { 'label', 'status_id', 'assign' (keep | author | role:<id>), 'comment' ('1'), 'project_ids' => [] }
      'done_actions' => [],
      'comment_template' => 'Erledigt in {zeitraum}, {stunden} gebucht.',
      # Pool: nicht zugewiesene Tickets, die in diesen Monaten geändert wurden
      'pool_months' => '6',
      # Teamrunde: Wochentag (1 = Montag … 5 = Freitag)
      'meeting_wday' => '1',
      # Erinnerung per Mail vor der Runde
      'reminder_enabled' => '1',
      'reminder_time' => 'eve16', # eve16, eve9, day8
      'reminder_recipients' => 'open', # open, all
      # Mail an die Person, wenn jemand anderes ihre Planung ändert
      'notify_on_foreign_edit' => '1',
      # Tracker für schnell angelegte Aufgaben; leer: "To-Do", sonst der erste des Projekts
      'tracker_id' => ''
    }.freeze

    DEFAULT_DONE_STATUS_NAMES = ['Resolved', 'For Billing'].freeze
    REMINDER_TIMES = { 'eve16' => [-1, 16], 'eve9' => [-1, 9], 'day8' => [0, 8] }.freeze

    module_function

    def all
      DEFAULTS.merge((Setting.plugin_redmine_team_planning || {}).to_h.stringify_keys)
    end

    def [](key)
      all[key.to_s]
    end

    def enabled?(key)
      self[key].to_s == '1'
    end

    def done_status_ids
      ids = Array(self['done_status_ids']).reject(&:blank?).map(&:to_i)
      return ids if ids.any?

      IssueStatus.where(is_closed: true).or(IssueStatus.where(name: DEFAULT_DONE_STATUS_NAMES)).pluck(:id)
    end

    # Abschluss-Aktionen als Liste von Hashes (das Formular liefert einen
    # Hash mit Indizes, gespeicherte Werte können beides sein)
    def done_actions
      raw = self['done_actions']
      list = raw.is_a?(Hash) ? raw.sort_by { |k, _| k.to_i }.map(&:last) : Array(raw)
      list.filter_map do |action|
        action = action.to_h.stringify_keys
        next if action['label'].blank? || action['status_id'].blank?

        { 'id' => action['id'].presence || Digest::SHA1.hexdigest(action['label'])[0, 8],
          'label' => action['label'].to_s.strip, 'status_id' => action['status_id'].to_i,
          'assign' => action['assign'].presence || 'keep', 'comment' => action['comment'].to_s == '1',
          'project_ids' => Array(action['project_ids']).reject(&:blank?).map(&:to_i) }
      end
    end

    def pool_months
      [self['pool_months'].to_i, 1].max
    end

    def meeting_wday
      self['meeting_wday'].to_i.clamp(1, 5)
    end

    def tracker_for(project)
      trackers = project.trackers.to_a
      tracker = trackers.find { |t| t.id == self['tracker_id'].to_i } if self['tracker_id'].present?
      tracker || trackers.find { |t| t.name.casecmp?('To-Do') || t.name.casecmp?('To-do') } || trackers.first
    end
  end
end
