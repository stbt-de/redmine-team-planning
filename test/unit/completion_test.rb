# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class CompletionTest < ActiveSupport::TestCase
  include RedmineTeamPlanning::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
    User.current = @jsmith
    @planner = planner_for(@jsmith)
    @issue = create_issue(assigned_to: @jsmith, author: @dlopper)
    @planner.move(@issue, to: MONDAY.iso8601)
    log_time(@jsmith, @issue, 3.5, MONDAY)
  end

  def configure(actions)
    Setting.plugin_redmine_team_planning = Setting.plugin_redmine_team_planning.merge('done_actions' => actions)
  end

  def test_ohne_aktionen_nur_abhaken
    configure([])
    completion = RedmineTeamPlanning::Completion.new(@planner, @issue)
    assert_empty completion.options
    completion.complete
    assert @planner.done?(completion.item.reload)
    assert_equal 1, @issue.reload.status_id
  end

  # Abrechnen: Status For Billing (hier Resolved), an die Rolle "Manager", mit Kommentar
  def test_aktion_setzt_status_weist_rolle_zu_und_kommentiert
    Member.create!(principal: User.find(8), project: @project, role_ids: [1]) if Member.where(user_id: 8, project_id: 1).none?
    configure([{ 'id' => 'bill', 'label' => 'Abrechnen', 'status_id' => '3', 'assign' => 'role:1', 'comment' => '1', 'project_ids' => [] }])
    completion = RedmineTeamPlanning::Completion.new(@planner, @issue)
    option = completion.options.first
    assert option.enabled?, option.disabled_reason
    assert_equal 'Abrechnen', option.label

    completion.complete('bill')
    @issue.reload
    assert_equal 3, @issue.status_id
    assert_equal 'Manager', @issue.assigned_to.roles_for_project(@project).first.name
    assert_equal 'Erledigt in KW 48, 3,5 h gebucht.', @issue.journals.last.notes
  end

  def test_aktion_nur_fuer_gewaehlte_projekte
    configure([{ 'id' => 'x', 'label' => 'Nur Projekt 2', 'status_id' => '3', 'assign' => 'keep', 'project_ids' => ['2'] }])
    assert_empty RedmineTeamPlanning::Completion.new(@planner, @issue).options
  end

  def test_workflow_sperrt_aktion_mit_grund
    WorkflowTransition.where(role_id: 1, tracker_id: @issue.tracker_id, old_status_id: 1, new_status_id: 6).delete_all
    configure([{ 'id' => 'reject', 'label' => 'Ablehnen', 'status_id' => '6', 'assign' => 'keep' }])
    completion = RedmineTeamPlanning::Completion.new(@planner, @issue)
    option = completion.options.first
    assert_not option.enabled?
    assert_match(/workflow/i, option.disabled_reason)
    assert_raises(RedmineTeamPlanning::Planner::Error) { completion.complete('reject') }
    assert_equal 1, @issue.reload.status_id
  end

  def test_rolle_ohne_mitglied_sperrt_aktion
    configure([{ 'id' => 'r', 'label' => 'An Reporter', 'status_id' => '3', 'assign' => 'role:3' }])
    Member.joins(:member_roles).where(project_id: @project.id, member_roles: { role_id: 3 }).destroy_all
    option = RedmineTeamPlanning::Completion.new(@planner, @issue).options.first
    assert_not option.enabled?
    assert_match(/Reporter/, option.disabled_reason)
  end

  def test_wieder_oeffnen_nimmt_status_und_zuweisung_zurueck
    configure([{ 'id' => 'author', 'label' => 'Zur Abnahme', 'status_id' => '4', 'assign' => 'author' }])
    completion = RedmineTeamPlanning::Completion.new(@planner, @issue)
    completion.complete('author')
    assert_equal [4, @dlopper.id], [@issue.reload.status_id, @issue.assigned_to_id]

    RedmineTeamPlanning::Completion.new(@planner, @issue).reopen
    @issue.reload
    assert_equal [1, @jsmith.id], [@issue.status_id, @issue.assigned_to_id]
    assert_not @planner.done?(@planner.items(@planner.current_period).first)
  end

  def test_status_aus_der_liste_zaehlt_als_erledigt
    @issue.update!(status: IssueStatus.find(3)) # Resolved
    assert @planner.done?(@planner.items(@planner.current_period).first)
  end
end
