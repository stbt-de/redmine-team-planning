# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ImportTest < ActiveSupport::TestCase
  include RedmineTeamPlanning::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
    User.current = User.find(1) # admin
    @field = IssueCustomField.create!(name: 'Planning Week', field_format: 'list', is_for_all: true,
                                      possible_values: ['Backlog'] + (1..53).map { |n| format('KW %02d', n) },
                                      tracker_ids: Tracker.pluck(:id))
  end

  def issue_with(value, assigned_to: @jsmith)
    issue = create_issue(assigned_to: assigned_to)
    CustomValue.create!(custom_field: @field, customized: issue, value: value)
    issue
  end

  def test_kalenderwochen_werden_zu_zeitraeumen
    this_week = issue_with('KW 48')
    next_week = issue_with('KW 49')
    past_week = issue_with('KW 45')
    backlog = issue_with('Backlog')
    unassigned = issue_with('KW 48', assigned_to: nil)

    result = RedmineTeamPlanning::Import.new(@field, year: 2026, today: MONDAY + 2).call
    planner = planner_for(@jsmith)
    assert_equal({ planned: 2, carried: 1, skipped: 1 }, result)
    assert_equal [this_week.id, past_week.id].sort, location_ids(planner, MONDAY.iso8601).sort
    assert_equal [next_week.id], location_ids(planner, (MONDAY + 7).iso8601)
    assert_equal 'carried', planner.items(planner.current_period).find { |i| i.issue_id == past_week.id }.origin
    assert_equal 'backlog', planner.location(backlog)
    assert_equal 'pool', planner.location(unassigned)
  end

  def test_zweiter_lauf_aendert_nichts
    issue_with('KW 49')
    RedmineTeamPlanning::Import.new(@field, year: 2026, today: MONDAY + 2).call
    result = RedmineTeamPlanning::Import.new(@field, year: 2026, today: MONDAY + 2).call
    assert_equal 0, result[:planned]
  end
end
