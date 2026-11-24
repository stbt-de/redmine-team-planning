# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ClosingOverviewTest < ActiveSupport::TestCase
  include RedmineTeamPlanning::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
    User.current = @jsmith
  end

  def friday
    MONDAY + 4
  end

  def states(overview)
    overview.entries.to_h { |entry| [entry.user, entry.state] }
  end

  # Ohne Woche: die Woche vor der nächsten Teamrunde (Montag), also KW 48
  def test_standardwoche_ist_die_vor_der_teamrunde
    overview = RedmineTeamPlanning::ClosingOverview.new(@jsmith, today: friday)
    assert_equal MONDAY, overview.week_start
    assert overview.default?
    assert_equal 'KW 48', overview.label
    assert_equal MONDAY - 7, overview.previous_week
    # Beliebiger Tag wird zum Montag, Unsinn zur Standardwoche
    assert_equal MONDAY, RedmineTeamPlanning::ClosingOverview.new(@jsmith, week: (MONDAY + 3).iso8601, today: friday).week_start
    assert_equal MONDAY, RedmineTeamPlanning::ClosingOverview.new(@jsmith, week: 'kw48', today: friday).week_start
  end

  def test_abgeschlossen_offen_laeuft_weiter
    planner_for(@jsmith, today: friday).current_period
    TeamPlanningUserSetting.create!(user: @dlopper, weeks: 2)
    planner_for(@dlopper, today: friday).current_period # KW 48–49

    overview = RedmineTeamPlanning::ClosingOverview.new(@jsmith, today: friday)
    assert_equal :open, states(overview)[@jsmith]
    assert_equal :running, states(overview)[@dlopper]
    assert_equal 0, overview.closed_count

    RedmineTeamPlanning::Closing.new(planner_for(@jsmith, today: friday)).call(decisions: {})
    overview = RedmineTeamPlanning::ClosingOverview.new(@jsmith, today: friday)
    assert_equal :closed, states(overview)[@jsmith]
    assert_equal 1, overview.closed_count
    assert_equal @jsmith, overview.entries.find { |e| e.state == :closed }.user
  end

  # Wer einen älteren Zeitraum nie abgeschlossen hat, liegt zurück: offen
  # mit dem alten Zeitraum, nicht "kein Zeitraum"
  def test_offener_alter_zeitraum_zaehlt_als_offen
    TeamPlanningPeriod.create!(user: @dlopper, starts_on: MONDAY - 14, weeks: 1)
    overview = RedmineTeamPlanning::ClosingOverview.new(@jsmith, today: friday)
    entry = overview.entries.find { |e| e.user == @dlopper }
    assert_equal :open, entry.state
    assert_equal MONDAY - 14, entry.period.starts_on
  end

  def test_ohne_zeitraum_und_offene_zuerst
    planner_for(@jsmith, today: friday).current_period
    overview = RedmineTeamPlanning::ClosingOverview.new(@jsmith, week: (MONDAY - 7).iso8601, today: friday)
    assert_equal :none, states(overview)[@jsmith]

    overview = RedmineTeamPlanning::ClosingOverview.new(@jsmith, today: friday)
    order = overview.entries.map(&:state)
    assert_equal order.sort_by { |s| RedmineTeamPlanning::ClosingOverview::STATE_ORDER.index(s) }, order
  end
end
