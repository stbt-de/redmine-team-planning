# frozen_string_literal: true

# Mails von Team Planning: Erinnerung vor der Teamrunde und Hinweis, wenn
# jemand anderes die eigene Planung geändert hat
class TeamPlanningMailer < Mailer
  # Verschickt die Erinnerung an alle Empfänger, einmal je Runde
  def self.deliver_reminders(now: Time.current)
    team_round = RedmineTeamPlanning::TeamRound.new(nil, today: now.to_date)
    return 0 unless team_round.reminder_due?(now)

    recipients = team_round.reminder_recipients
    recipients.each { |user| reminder(user, team_round.meeting_on).deliver_later }
    team_round.round.update!(reminded_at: now)
    recipients.size
  end

  def self.deliver_plan_changed(user, editor, change)
    return unless RedmineTeamPlanning::Settings.enabled?('notify_on_foreign_edit')
    return if user == editor || user.mail.blank?

    plan_changed(user, editor, change).deliver_later
  end

  def reminder(user, meeting_on)
    @user = user
    @meeting_on = meeting_on
    @planner = RedmineTeamPlanning::Planner.new(user, user, today: meeting_on - 1)
    @period = @planner.current_period
    @items = @planner.items(@period)
    @done = @items.count { |item| @planner.done?(item) }
    @booked = @planner.booked_hours(@period)
    @url = url_for(controller: 'team_planning', action: 'close')
    mail to: user, subject: l(:mail_subject_team_planning_reminder, date: format_date(meeting_on))
  end

  def plan_changed(user, editor, change)
    @user = user
    @editor = editor
    @change = change
    @url = url_for(controller: 'team_planning', action: 'show')
    mail to: user, subject: l(:mail_subject_team_planning_changed, name: editor.name)
  end
end
