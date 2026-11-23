# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class TeamPlanningIntegrationTest < Redmine::IntegrationTest
  include RedmineTeamPlanning::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
    travel_to MONDAY.in_time_zone.change(hour: 10) + 2.days
    User.where(id: [1, 2, 3]).update_all(language: 'de')
    log_user('jsmith', 'jsmith')
  end

  def log_in_as(login, password)
    reset!
    log_user(login, password)
  end

  def teardown
    travel_back
  end

  def json
    JSON.parse(response.body)
  end

  def test_board_zeigt_spalten_und_menue
    issue = create_issue(assigned_to: @jsmith, subject: 'Landingpage Ostern')
    get '/team_planning'
    assert_response :success
    assert_select '#top-menu a.team-planning', text: 'Planung'
    assert_select '.tp-col', minimum: 6 # Backlog, 4 Zeiträume, Später
    assert_select '.tp-cards[data-location=backlog] .tp-card[data-issue-id=?]', issue.id.to_s
    assert_select '.tp-cards[data-location=?]', MONDAY.iso8601
    assert_select 'a.tp-btn-primary', text: 'KW 48 abschließen'
    assert_select 'link[href*=team_planning]'
  end

  def test_ziehen_buchen_abhaken_ueber_json
    issue = create_issue(assigned_to: @jsmith)
    post "/team_planning/issues/#{issue.id}/move", params: { to: MONDAY.iso8601, position: 0 }, as: :json
    assert_response :success
    assert_match(/KW 48/, json['message'])
    assert_equal 'backlog', json.dig('undo', 'params', 'to')

    patch "/team_planning/issues/#{issue.id}", params: { planned_hours: '1,5' }, as: :json
    assert_response :success
    assert_equal 1.5, TeamPlanningItem.find_by(issue_id: issue.id).planned_hours.to_f

    post "/team_planning/issues/#{issue.id}/time", params: { hours: '0,5' }, as: :json
    assert_response :success
    entry = TimeEntry.where(issue_id: issue.id, user_id: @jsmith.id).last
    assert_equal 0.5, entry.hours

    delete "/team_planning/issues/#{issue.id}/time/#{entry.id}", as: :json
    assert_response :success
    assert_not TimeEntry.exists?(entry.id)

    get "/team_planning/issues/#{issue.id}/done_options"
    assert_equal [], json
    post "/team_planning/issues/#{issue.id}/complete", as: :json
    assert_response :success
    assert TeamPlanningItem.find_by(issue_id: issue.id).done
  end

  # Regression (23.11.2026, Browser-Test): Der Block schickt spent_on leer,
  # wenn der Zeitraum keinen Tag bis heute hat; Redmine meldete "Datum muss
  # ausgefüllt werden". Leeres Datum heißt jetzt: heute.
  def test_buchen_ohne_datum_bucht_auf_heute
    issue = create_issue(assigned_to: @jsmith)
    post "/team_planning/issues/#{issue.id}/time", params: { hours: '1', spent_on: '', comments: '', activity_id: '' }, as: :json
    assert_response :success, response.body
    assert_equal Date.current, TimeEntry.where(issue_id: issue.id).last.spent_on
  end

  def test_aufgabe_anlegen_und_abwesenheit
    post '/team_planning/issues', params: { subject: 'Neue Aufgabe', project_id: 1, to: (MONDAY + 7).iso8601 }, as: :json
    assert_response :success
    issue = Issue.find(json['issue_id'])
    assert_equal @jsmith, issue.assigned_to

    patch "/team_planning/periods/#{(MONDAY + 7).iso8601}/absence", params: { days: 2 }, as: :json
    assert_response :success
    assert_equal 2, TeamPlanningPeriod.find_by(user_id: @jsmith.id, starts_on: MONDAY + 7).absence_days
  end

  def test_fehler_kommen_als_json
    issue = create_issue(assigned_to: @jsmith)
    post "/team_planning/issues/#{issue.id}/move", params: { to: '2020-01-06' }, as: :json
    assert_response 422
    assert json['error'].present?
  end

  def test_fremde_planung_nur_lesen_fuer_mitarbeitende
    issue = create_issue(assigned_to: @jsmith)
    log_in_as('dlopper', 'foo')
    get "/team_planning?user_id=#{@jsmith.id}"
    assert_response :success
    assert_select '.tp-board.is-readonly'
    assert_select '.tp-banner', text: /Nur lesen/

    post "/team_planning/issues/#{issue.id}/move?user_id=#{@jsmith.id}", params: { to: MONDAY.iso8601 }, as: :json
    assert_response 422
    assert_equal 'backlog', planner_for(@jsmith).location(issue)
  end

  def test_projektleitung_bearbeitet_fremde_planung_mit_mail
    issue = create_issue(assigned_to: @dlopper)
    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      post "/team_planning/issues/#{issue.id}/move?user_id=#{@dlopper.id}", params: { to: MONDAY.iso8601 }, as: :json
    end
    assert_response :success
    assert_equal MONDAY.iso8601, planner_for(@dlopper).location(issue)
    assert_equal [@dlopper.mail], ActionMailer::Base.deliveries.last&.to
  end

  def test_ohne_recht_kein_zugriff
    Role.find(2).remove_permission!(:use_team_planning, :view_others_team_planning)
    log_in_as('dlopper', 'foo')
    get '/team_planning'
    assert_response 403
  end

  def test_abschliessen_ueber_formular
    issue = create_issue(assigned_to: @jsmith)
    planner_for(@jsmith).move(issue, to: MONDAY.iso8601)
    get '/team_planning/close'
    assert_response :success
    assert_select "input[type=radio][name='decisions[#{issue.id}]']", 3

    post '/team_planning/close', params: { decisions: { issue.id => 'next' }, review: { good: 'Lief' }, focus: 'Fokus' }
    assert_redirected_to '/team_planning'
    follow_redirect!
    assert_select '.flash.notice', text: /KW 48 abgeschlossen/
    assert_equal 'Lief', TeamPlanningPeriod.find_by(user_id: @jsmith.id, starts_on: MONDAY).review_good
  end

  def test_abschluss_ohne_entscheidung_zeigt_fehler
    issue = create_issue(assigned_to: @jsmith)
    planner_for(@jsmith).move(issue, to: MONDAY.iso8601)
    post '/team_planning/close', params: { decisions: {} }
    assert_response 422
    assert_select '.flash.error, #flash_error', text: /Entscheidung/
  end

  def test_teamrunde_mit_notizen
    get '/team_planning/team'
    assert_response :success
    assert_select '.tp-person', minimum: 2
    patch '/team_planning/round', params: { notes: 'Aktionen im Dezember' }, as: :json
    assert_response :success
    assert_equal 'Aktionen im Dezember', TeamPlanningRound.find_by(held_on: MONDAY + 7).notes
    get '/team_planning/team?mode=project'
    assert_response :success
  end

  def test_block_auf_meine_seite
    issue = create_issue(assigned_to: @jsmith, subject: 'Im Plan')
    planner_for(@jsmith).move(issue, to: MONDAY.iso8601)
    @jsmith.pref.my_page_layout = { 'top' => ['team_plan'] }
    @jsmith.pref.save!
    get '/my/page'
    assert_response :success
    assert_select '#block-team_plan .tp-wrow[data-issue-id=?]', issue.id.to_s
    assert_select '#block-team_plan .tp-wbook button[data-hours]', 3
  end

  def test_einstellungen_speichern
    log_in_as('admin', 'admin')
    get '/settings/plugin/redmine_team_planning'
    assert_response :success
    post '/settings/plugin/redmine_team_planning', params: { settings: {
      done_actions: { '0' => { label: 'Abrechnen', status_id: '3', assign: 'role:1', comment: '1', project_ids: [''] },
                      '1' => { label: '', status_id: '' } },
      meeting_wday: '2', reminder_enabled: '1'
    } }
    assert_response :redirect
    actions = RedmineTeamPlanning::Settings.done_actions
    assert_equal 1, actions.size
    assert_equal({ 'label' => 'Abrechnen', 'status_id' => 3, 'assign' => 'role:1', 'comment' => true, 'project_ids' => [] },
                 actions.first.except('id'))
    assert_equal 2, RedmineTeamPlanning::Settings.meeting_wday
  end
end
