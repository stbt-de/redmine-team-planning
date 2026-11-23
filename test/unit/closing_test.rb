# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ClosingTest < ActiveSupport::TestCase
  include RedmineTeamPlanning::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
    User.current = @jsmith
    @planner = planner_for(@jsmith, today: MONDAY + 4)
    @key = MONDAY.iso8601
  end

  def test_abschluss_braucht_eine_entscheidung_je_offenem_ticket
    issue = create_issue(assigned_to: @jsmith)
    @planner.move(issue, to: @key)
    closing = RedmineTeamPlanning::Closing.new(@planner)
    error = assert_raises(RedmineTeamPlanning::Planner::Error) { closing.call(decisions: {}) }
    assert_match(/1/, error.message)
    assert_nil @planner.current_period.reload.closed_at
  end

  def test_abschluss_uebertraegt_legt_zurueck_und_schliesst
    to_next = create_issue(assigned_to: @jsmith)
    to_backlog = create_issue(assigned_to: @jsmith)
    to_close = create_issue(assigned_to: @jsmith)
    done = create_issue(assigned_to: @jsmith)
    long = create_issue(assigned_to: @jsmith)
    standing = create_issue(assigned_to: @jsmith)
    [to_next, to_backlog, to_close, done, long].each { |i| @planner.move(i, to: @key) }
    @planner.update_item(long, kind: 'long', until_on: (MONDAY + 14).iso8601)
    @planner.move(standing, to: 'standing')
    done.update!(status: IssueStatus.find(5))

    closed = RedmineTeamPlanning::Closing.new(@planner).call(
      decisions: { to_next.id.to_s => 'next', to_backlog.id.to_s => 'backlog', to_close.id.to_s => 'close' },
      review: { good: 'Gewinnspiel lief', bad: 'Video fehlt', change: '' }, focus: 'Advent fertig',
      notes: "Agentur wegen Videos anrufen\n- Rechnung prüfen"
    )

    assert closed.closed?
    assert_equal 'Gewinnspiel lief', closed.review_good
    assert_equal "Agentur wegen Videos anrufen\n- Rechnung prüfen", closed.notes
    results = closed.items.to_h { |item| [item.issue_id, item.result] }
    assert_equal({ to_next.id => 'carried', to_backlog.id => 'backlog', to_close.id => 'closed', done.id => 'done',
                   long.id => 'carried' }, results)

    current = @planner.current_period
    assert_equal MONDAY + 7, current.starts_on
    assert_equal 'Advent fertig', current.focus
    assert_equal [to_next.id, long.id].sort, @planner.items(current).map(&:issue_id).sort
    assert(@planner.items(current).all? { |item| item.origin == 'carried' })
    assert @planner.items(current).find { |item| item.issue_id == long.id }.long?
    assert to_close.reload.closed?
    assert_includes @planner.backlog.map(&:id), to_backlog.id
    assert_equal [standing.id], @planner.standings.map(&:issue_id), 'Dauerthemen laufen weiter'
    assert_equal 1, @planner.carries(to_next)
    assert_equal closed, @planner.past_period
  end

  def test_langlaeufer_nach_der_zielwoche_braucht_eine_entscheidung
    long = create_issue(assigned_to: @jsmith)
    @planner.move(long, to: @key)
    @planner.update_item(long, kind: 'long', until_on: MONDAY.iso8601)
    closing = RedmineTeamPlanning::Closing.new(@planner)
    assert_equal [long.id], closing.open_items.map(&:issue_id)
    assert_empty closing.automatic_items
  end

  def test_dauerthema_beim_abschluss_beenden
    standing = create_issue(assigned_to: @jsmith)
    @planner.move(standing, to: 'standing')
    RedmineTeamPlanning::Closing.new(@planner).call(decisions: {}, end_standing: [standing.id])
    assert_empty @planner.standings
    assert standing.reload.closed?
  end

  def test_dreimal_uebertragen_wird_gezaehlt
    issue = create_issue(assigned_to: @jsmith)
    @planner.move(issue, to: @key)
    3.times do |n|
      planner = planner_for(@jsmith, today: MONDAY + (7 * n) + 4)
      RedmineTeamPlanning::Closing.new(planner).call(decisions: { issue.id => 'next' })
    end
    assert_equal 3, planner_for(@jsmith, today: MONDAY + 25).carries(issue)
  end
end
