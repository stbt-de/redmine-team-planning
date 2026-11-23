# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class TeamRoundTest < ActiveSupport::TestCase
  include RedmineTeamPlanning::TestHelper
  include ActionMailer::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
    User.current = @jsmith
    ActionMailer::Base.deliveries.clear
  end

  def friday
    MONDAY + 4
  end

  def test_naechster_termin_am_eingestellten_tag
    round = RedmineTeamPlanning::TeamRound.new(@jsmith, today: friday)
    assert_equal MONDAY + 7, round.meeting_on
    Setting.plugin_redmine_team_planning = Setting.plugin_redmine_team_planning.merge('meeting_wday' => '5')
    assert_equal friday, RedmineTeamPlanning::TeamRound.new(@jsmith, today: friday).meeting_on
  end

  def test_vorbereitet_offen_und_laeuft_weiter
    planner_for(@jsmith, today: friday).current_period
    TeamPlanningUserSetting.create!(user: @dlopper, weeks: 2)
    planner_for(@dlopper, today: friday).current_period # KW 48–49

    round = RedmineTeamPlanning::TeamRound.new(@jsmith, today: friday)
    states = round.entries.to_h { |entry| [entry.user, entry.state] }
    assert_equal :open, states[@jsmith]
    assert_equal :running, states[@dlopper]

    RedmineTeamPlanning::Closing.new(planner_for(@jsmith, today: friday)).call(decisions: {})
    round = RedmineTeamPlanning::TeamRound.new(@jsmith, today: friday)
    assert_equal :prepared, round.entries.find { |e| e.user == @jsmith }.state
  end

  def test_nach_projekt_gruppiert_ueber_alle_personen
    a = create_issue(assigned_to: @jsmith)
    b = create_issue(assigned_to: @dlopper)
    planner_for(@jsmith, today: friday).move(a, to: (MONDAY + 7).iso8601)
    planner_for(@dlopper, @jsmith, today: friday).move(b, to: (MONDAY + 7).iso8601)
    groups = RedmineTeamPlanning::TeamRound.new(@jsmith, today: friday).by_project.to_h
    assert_equal [a.id, b.id].sort, groups[@project].map { |issue, _, _| issue.id }.sort
  end

  def test_erinnerung_einmal_je_runde_an_wer_noch_nicht_vorbereitet_hat
    planner_for(@jsmith, today: friday).current_period
    RedmineTeamPlanning::Closing.new(planner_for(@dlopper, today: friday)).call(decisions: {})
    sunday_evening = (MONDAY + 6).in_time_zone.change(hour: 17)

    perform_enqueued_jobs do
      assert TeamPlanningMailer.deliver_reminders(now: sunday_evening).positive?
      assert_equal 0, TeamPlanningMailer.deliver_reminders(now: sunday_evening + 1.hour), 'nur einmal je Runde'
    end
    recipients = ActionMailer::Base.deliveries.flat_map(&:to)
    assert_includes recipients, @jsmith.mail
    assert_not_includes recipients, @dlopper.mail, 'wer vorbereitet hat, bekommt keine Erinnerung'
    mail = ActionMailer::Base.deliveries.find { |m| m.to == [@jsmith.mail] }
    assert_match(/bitte vorbereiten|please prepare/, mail.subject)
  end

  def test_keine_erinnerung_vor_dem_zeitpunkt_oder_wenn_aus
    sunday_noon = (MONDAY + 6).in_time_zone.change(hour: 12)
    assert_equal 0, TeamPlanningMailer.deliver_reminders(now: sunday_noon)
    Setting.plugin_redmine_team_planning = Setting.plugin_redmine_team_planning.merge('reminder_enabled' => '0')
    assert_equal 0, TeamPlanningMailer.deliver_reminders(now: sunday_noon + 6.hours)
  end

  def test_mail_wenn_jemand_anderes_die_planung_aendert
    perform_enqueued_jobs do
      TeamPlanningMailer.deliver_plan_changed(@dlopper, @jsmith, '#1 nach KW 49 verschoben')
      TeamPlanningMailer.deliver_plan_changed(@jsmith, @jsmith, 'eigene Änderung')
    end
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal [@dlopper.mail], ActionMailer::Base.deliveries.last.to
  end
end
