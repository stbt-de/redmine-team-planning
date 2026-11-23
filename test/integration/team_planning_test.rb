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
    assert_select 'textarea#notes.wiki-edit'

    post '/team_planning/close', params: { decisions: { issue.id => 'next' }, review: { good: 'Lief' }, focus: 'Fokus',
                                           notes: 'Nur für mich' }
    assert_redirected_to '/team_planning'
    follow_redirect!
    assert_select '.flash.notice', text: /KW 48 abgeschlossen/
    closed = TeamPlanningPeriod.find_by(user_id: @jsmith.id, starts_on: MONDAY)
    assert_equal 'Lief', closed.review_good
    assert_equal 'Nur für mich', closed.notes
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

  def test_erledigt_status_automatisch_oder_selbst_gewaehlt
    IssueStatus.find(3).update!(name: '✅ Resolved')
    log_in_as('admin', 'admin')
    get '/settings/plugin/redmine_team_planning'
    assert_response :success
    assert_select 'input[name=?][value=auto][checked]', 'settings[done_status_mode]'
    # Vorbelegt ist, was gerade zählt; abgeschaltet, solange "Automatisch" gilt
    assert_select 'input#settings_done_status_3[checked][disabled]'
    assert_select 'input#settings_done_status_5[checked]'
    assert_select 'input#settings_done_status_1:not([checked])'

    post '/settings/plugin/redmine_team_planning', params: { settings: {
      done_status_mode: 'custom', done_status_ids: ['', '3', '5', '6']
    } }
    assert_response :redirect
    assert_equal [3, 5, 6], RedmineTeamPlanning::Settings.done_status_ids.sort
    get '/settings/plugin/redmine_team_planning'
    assert_select 'input[name=?][value=custom][checked]', 'settings[done_status_mode]'
    assert_select 'input#settings_done_status_3[checked]:not([disabled])'

    post '/settings/plugin/redmine_team_planning', params: { settings: { done_status_mode: 'auto' } }
    assert_includes RedmineTeamPlanning::Settings.done_status_ids, 3
    assert_not RedmineTeamPlanning::Settings.done_statuses_customized?
  end

  # --- Frühere Zeiträume ------------------------------------------------------

  def closed_period(user, starts_on, **attributes)
    TeamPlanningPeriod.create!(user: user, starts_on: starts_on, weeks: 1, closed_at: starts_on.to_time + 5.days, **attributes)
  end

  def test_detailseite_eines_abgeschlossenen_zeitraums
    issue = create_issue(assigned_to: @jsmith, subject: 'Startseite überarbeiten')
    period = closed_period(@jsmith, MONDAY - 14, focus: 'Startseite fertig', review_good: 'Abstimmung lief schnell',
                                                 review_bad: 'Zu viele Unterbrechungen', review_change: 'Fokuszeit am Vormittag')
    TeamPlanningItem.create!(period: period, issue: issue, position: 1, kind: 'normal', origin: 'planned', result: 'done')
    TeamPlanningRound.create!(held_on: MONDAY - 14, notes: 'Urlaubsplanung bis Freitag')
    TeamPlanningRound.create!(held_on: MONDAY - 7, notes: 'Notiz aus der Folgewoche')

    get "/team_planning/periods/#{(MONDAY - 14).iso8601}"
    assert_response :success
    assert_select 'h2', 'KW 46'
    assert_select '.tp-list-row', text: /Startseite überarbeiten/
    assert_select '.tp-pill.tp-result-done'
    assert_select '.tp-review-cols', text: /Abstimmung lief schnell/
    assert_select '.tp-review-cols', text: /Zu viele Unterbrechungen/
    assert_select '.tp-review-cols', text: /Fokuszeit am Vormittag/
    assert_select '.tp-panel', text: /Startseite fertig/
    assert_select '.tp-round-note', text: /Urlaubsplanung bis Freitag/
    assert_select '.tp-round-note', text: /Notiz aus der Folgewoche/, count: 0
  end

  def test_detailseite_nur_fuer_abgeschlossene_zeitraeume
    TeamPlanningPeriod.create!(user: @jsmith, starts_on: MONDAY, weeks: 1)
    get "/team_planning/periods/#{MONDAY.iso8601}"
    assert_response 404
    get '/team_planning/periods/2026-02-30'
    assert_response 404
  end

  def test_fremde_zeitraeume_nur_mit_recht
    closed_period(@jsmith, MONDAY - 7, review_good: 'Gut so')
    log_in_as('dlopper', 'foo')
    get "/team_planning/periods/#{(MONDAY - 7).iso8601}", params: { user_id: @jsmith.id }
    assert_response :success
    assert_select '.tp-review-cols', text: /Gut so/

    Role.find(2).remove_permission!(:view_others_team_planning)
    get "/team_planning/periods/#{(MONDAY - 7).iso8601}", params: { user_id: @jsmith.id }
    assert_response 403
    get '/team_planning/periods', params: { user_id: @jsmith.id }
    assert_response 403
  end

  def test_uebersicht_und_blaettern_im_board
    closed_period(@jsmith, MONDAY - 14, review_good: 'Älterer Rückblick')
    closed_period(@jsmith, MONDAY - 7, review_good: 'Neuerer Rückblick')

    get '/team_planning/periods'
    assert_response :success
    assert_select 'a.tp-period-link', 2
    assert_select '.tp-period-row', text: /Älterer Rückblick/

    # Board zeigt den letzten Zeitraum, blättert zum älteren und zurück
    get '/team_planning', params: { partial: 'board' }
    assert_select '.tp-col.is-past[data-past-on=?]', (MONDAY - 7).iso8601
    assert_select '[data-tp-past-nav=?]', (MONDAY - 14).iso8601
    get '/team_planning', params: { partial: 'board', past: (MONDAY - 14).iso8601 }
    assert_select '.tp-col.is-past[data-past-on=?]', (MONDAY - 14).iso8601
    assert_select '[data-tp-past-nav=?]', (MONDAY - 7).iso8601
    assert_select 'a[href=?]', "/team_planning/periods/#{(MONDAY - 14).iso8601}"
  end

  def test_zeitraum_nachtraeglich_bearbeiten
    period = closed_period(@jsmith, MONDAY - 7, review_good: 'Alt gut', focus: 'Alter Fokus')
    round = TeamPlanningRound.create!(held_on: MONDAY - 7, notes: 'Alte Notiz')
    path = "/team_planning/periods/#{(MONDAY - 7).iso8601}"

    get path
    assert_select 'a[href=?]', "#{path}?edit=1"
    get path, params: { edit: 1 }
    assert_select 'form.tp-period-form textarea#period_review_good', text: /Alt gut/
    assert_select "textarea#round_#{round.id}", text: /Alte Notiz/
    # Editor nur bei den Notizen, der Rückblick bleibt schlicht
    assert_select "textarea#round_#{round.id}.wiki-edit"
    assert_select 'textarea#period_review_good.wiki-edit', 0

    assert_select 'textarea#period_notes.wiki-edit'
    patch path, params: { period: { review_good: 'Neu gut', review_bad: 'Neu weniger gut', review_change: '', focus: 'Neuer Fokus',
                                    notes: '**Merken:** Angebot nachfassen' },
                          rounds: { round.id.to_s => 'Neue Notiz' } }
    assert_redirected_to path
    period.reload
    assert_equal 'Neu gut', period.review_good
    assert_equal 'Neu weniger gut', period.review_bad
    assert_nil period.review_change
    assert_equal 'Neuer Fokus', period.focus
    assert_equal '**Merken:** Angebot nachfassen', period.notes
    get path
    assert_select '.tp-personal-notes .wiki strong', 'Merken:'
    assert_equal 'Neue Notiz', round.reload.notes
  end

  def test_zeitraum_bearbeiten_nur_mit_recht
    period = closed_period(@jsmith, MONDAY - 7, review_good: 'Bleibt')
    path = "/team_planning/periods/#{(MONDAY - 7).iso8601}"
    log_in_as('dlopper', 'foo') # darf fremde Planung nur ansehen
    get path, params: { user_id: @jsmith.id, edit: 1 }
    assert_response :success
    assert_select 'form.tp-period-form', 0
    assert_select 'a[href*="edit=1"]', 0
    patch path, params: { user_id: @jsmith.id, period: { review_good: 'Geändert' } }
    assert_response 403
    assert_equal 'Bleibt', period.reload.review_good
  end

  def test_projektleitung_bearbeitet_fremden_rueckblick_mit_mail
    period = closed_period(@dlopper, MONDAY - 7, review_good: 'Alt')
    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      patch "/team_planning/periods/#{(MONDAY - 7).iso8601}", params: { user_id: @dlopper.id, period: { review_good: 'Ergänzt' } }
    end
    assert_response :redirect
    assert_equal 'Ergänzt', period.reload.review_good
    assert(ActionMailer::Base.deliveries.any? { |m| m.to.include?(@dlopper.mail) })
  end

  def test_rueckblick_und_notizen_mit_textformatierung
    issue = create_issue(assigned_to: @jsmith, subject: 'Verlinktes Ticket')
    closed_period(@jsmith, MONDAY - 7, review_good: "**Wichtig** war\n\n- Punkt eins\n- Punkt zwei\n\n<script>alert(1)</script>",
                                       review_bad: "- **Fett** und `Code` am Anfang")
    TeamPlanningRound.create!(held_on: MONDAY - 7, notes: "Siehe ##{issue.id}\n\n1. erstens\n2. zweitens")

    with_settings text_formatting: 'common_mark' do
      get "/team_planning/periods/#{(MONDAY - 7).iso8601}"
      assert_response :success
      assert_select '.tp-review-cols .wiki strong', 'Wichtig'
      assert_select '.tp-review-cols .wiki li', 3
      assert_select '.tp-review-cols script', 0
      assert_select '.tp-round-note .wiki a[href=?]', "/issues/#{issue.id}"
      assert_select '.tp-round-note .wiki ol li', 2

      # Kurzfassungen ohne Markdown-Zeichen
      get '/team_planning/periods'
      assert_select '.tp-period-review', text: /Wichtig war/
      assert_select '.tp-period-review', text: /Fett und Code am Anfang/
      assert_select '.tp-period-review', text: /\*\*|`/, count: 0
    end
  end
end
