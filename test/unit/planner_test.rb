# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class PlannerTest < ActiveSupport::TestCase
  include RedmineTeamPlanning::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
    User.current = @jsmith
    @planner = planner_for(@jsmith)
  end

  def test_laufender_zeitraum_beginnt_am_montag_und_drei_folgen
    periods = @planner.periods
    assert_equal MONDAY, periods.first.starts_on
    assert periods.first.persisted?
    assert_equal [MONDAY + 7, MONDAY + 14, MONDAY + 21], periods.drop(1).map(&:starts_on)
    assert_equal 'KW 48', periods.first.label
  end

  def test_verschieben_aus_backlog_mit_reihenfolge_und_zurueck
    first = create_issue(assigned_to: @jsmith)
    second = create_issue(assigned_to: @jsmith)
    key = MONDAY.iso8601
    assert_includes @planner.backlog.map(&:id), first.id

    @planner.move(first, to: key)
    @planner.move(second, to: key, position: 0)
    assert_equal [second.id, first.id], location_ids(@planner, key)
    assert_not_includes @planner.backlog.map(&:id), first.id

    undo = @planner.move(first, to: 'backlog')
    assert_equal({ from: key, position: 1, assigned: false }, undo)
    assert_includes @planner.backlog.map(&:id), first.id
  end

  # Ziehen aus dem Pool weist das Ticket der Person zu
  def test_pool_ticket_wird_beim_einplanen_zugewiesen
    issue = create_issue(assigned_to: nil)
    assert_includes @planner.pool.map(&:id), issue.id

    undo = @planner.move(issue, to: MONDAY.iso8601)
    assert undo[:assigned]
    assert_equal @jsmith.id, issue.reload.assigned_to_id
    assert_not_includes @planner.pool.map(&:id), issue.id

    @planner.unassign(issue)
    assert_nil issue.reload.assigned_to_id
    assert_includes @planner.pool.map(&:id), issue.id
  end

  def test_pool_zeigt_nur_kuerzlich_geaenderte_tickets
    old = create_issue(assigned_to: nil)
    Issue.where(id: old.id).update_all(updated_on: 8.months.ago)
    assert_not_includes @planner.pool.map(&:id), old.id
  end

  # Regression: Pool (und Backlog) zeigten Tickets aus geschlossenen Projekten.
  # Issue.visible schließt nur archivierte Projekte aus; geschlossene sind
  # sichtbar, aber schreibgeschützt – einplanen/zuweisen geht dort nicht.
  def test_pool_und_backlog_ohne_tickets_aus_geschlossenen_projekten
    unassigned = create_issue(assigned_to: nil)
    mine = create_issue(assigned_to: @jsmith)
    assert_includes @planner.pool.map(&:id), unassigned.id
    assert_includes @planner.backlog.map(&:id), mine.id

    @project.update_column(:status, Project::STATUS_CLOSED)
    planner = planner_for(@jsmith)
    assert_not_includes planner.pool.map(&:id), unassigned.id, 'Pool zeigt Ticket aus geschlossenem Projekt'
    assert_not_includes planner.backlog.map(&:id), mine.id, 'Backlog zeigt Ticket aus geschlossenem Projekt'
  end

  def test_ungeplant_wenn_der_laufende_zeitraum_schon_begonnen_hat
    issue = create_issue(assigned_to: @jsmith)
    @planner.move(issue, to: MONDAY.iso8601)
    assert_equal 'unplanned', @planner.items(@planner.current_period).first.origin

    later = create_issue(assigned_to: @jsmith)
    @planner.move(later, to: (MONDAY + 7).iso8601)
    assert_equal 'planned', @planner.items(@planner.periods[1]).first.origin
  end

  def test_dauerthema_hinein_und_wieder_heraus
    issue = create_issue(assigned_to: @jsmith)
    @planner.move(issue, to: 'standing')
    assert_equal [issue.id], @planner.standings.map(&:issue_id)
    assert_equal 'standing', @planner.location(issue)

    @planner.move(issue, to: MONDAY.iso8601)
    assert_empty @planner.standings
    assert_equal MONDAY.iso8601, @planner.location(issue)
  end

  def test_planstunden_und_langlaeufer_bleiben_beim_verschieben
    issue = create_issue(assigned_to: @jsmith)
    @planner.move(issue, to: MONDAY.iso8601)
    @planner.update_item(issue, planned_hours: 2.5, kind: 'long', until_on: (MONDAY + 14).iso8601)
    @planner.move(issue, to: (MONDAY + 7).iso8601)
    item = @planner.items(@planner.periods[1]).first
    assert_equal 2.5, item.planned_hours.to_f
    assert item.long?
    assert_equal MONDAY + 14, item.until_on
  end

  def test_abwesenheit_senkt_die_obergrenze_anteilig
    @planner.setting.update!(item_limit: 6)
    @planner.set_absence(MONDAY.iso8601, 2)
    assert_equal 4, @planner.effective_limit(@planner.current_period.reload)
    @planner.set_absence(MONDAY.iso8601, 5)
    assert_equal 0, @planner.effective_limit(@planner.current_period.reload)
  end

  # Zwei Wochen: künftige Zeiträume werden neu eingeteilt, Tickets bleiben
  def test_laengerer_zeitraum_teilt_kuenftige_zeitraeume_neu_ein
    a = create_issue(assigned_to: @jsmith)
    b = create_issue(assigned_to: @jsmith)
    @planner.move(a, to: (MONDAY + 7).iso8601)
    @planner.move(b, to: (MONDAY + 14).iso8601)

    @planner.update_settings(weeks: 2)
    periods = @planner.periods
    assert_equal 1, periods.first.weeks, 'der laufende Zeitraum bleibt'
    assert_equal [MONDAY + 7, MONDAY + 21, MONDAY + 35], periods.drop(1).map(&:starts_on)
    assert_equal 'KW 49–50', periods[1].label
    assert_equal [a.id, b.id], location_ids(@planner, (MONDAY + 7).iso8601)
  end

  def test_gebuchte_stunden_im_zeitraum_und_ausserhalb_des_plans
    planned = create_issue(assigned_to: @jsmith)
    other = create_issue(assigned_to: @jsmith)
    @planner.move(planned, to: MONDAY.iso8601)
    log_time(@jsmith, planned, 2, MONDAY)
    log_time(@jsmith, other, 1.5, MONDAY + 1)
    log_time(@jsmith, other, 4, MONDAY - 1) # Vorwoche

    period = @planner.current_period
    assert_equal 3.5, @planner.booked_hours(period)
    assert_equal 2.0, @planner.booked_for(planned, period)
    assert_equal 1.5, @planner.booked_outside(period)
  end

  def test_fremde_planung_ohne_recht_nur_lesen
    issue = create_issue(assigned_to: @jsmith)
    viewer = planner_for(@jsmith, @dlopper)
    assert RedmineTeamPlanning::Access.view?(@dlopper, @jsmith)
    assert_not viewer.editable?
    assert_raises(RedmineTeamPlanning::Planner::Error) { viewer.move(issue, to: MONDAY.iso8601) }

    lead = planner_for(@dlopper, @jsmith)
    assert lead.editable?, 'Projektleitung darf fremde Planungen bearbeiten'
  end

  def test_ohne_recht_keine_planung
    Role.find(2).remove_permission!(:use_team_planning, :view_others_team_planning)
    assert_not RedmineTeamPlanning::Access.use?(@dlopper)
    assert_not RedmineTeamPlanning::Access.view?(@dlopper, @jsmith)
  end

  def test_aufgabe_anlegen_und_einplanen
    issue = @planner.create_issue(subject: 'Kooperationsanfrage', project: @project, to: (MONDAY + 7).iso8601)
    assert issue.persisted?
    assert_equal @jsmith, issue.assigned_to
    assert_equal [issue.id], location_ids(@planner, (MONDAY + 7).iso8601)

    assert_no_difference 'Issue.count' do
      error = assert_raises(RedmineTeamPlanning::Planner::Error) { @planner.create_issue(subject: '', project: @project, to: 'backlog') }
      assert_equal Issue.new.tap(&:valid?).errors.full_messages_for(:subject).first, error.message
    end
  end

  def test_unbekannter_zeitraum_wird_abgelehnt
    issue = create_issue(assigned_to: @jsmith)
    assert_raises(RedmineTeamPlanning::Planner::Error) { @planner.move(issue, to: '2020-01-06') }
    assert_raises(RedmineTeamPlanning::Planner::Error) { @planner.move(issue, to: 'kaputt') }
  end
end
