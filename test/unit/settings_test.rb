# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class SettingsTest < ActiveSupport::TestCase
  include RedmineTeamPlanning::TestHelper
  fixtures(*RedmineTeamPlanning::TestHelper::FIXTURES)

  def setup
    setup_team_planning
  end

  # Regression: Die Vorgabe verglich Statusnamen exakt mit "Resolved" und
  # "For Billing". Heißen die Status "✅ Resolved" und "💰 For Billing"
  # (Emoji davor), zählten nur die geschlossenen Status (Closed, Rejected)
  # als erledigt.
  def test_vorgabe_erkennt_status_mit_emoji_und_anderer_schreibweise
    IssueStatus.find(3).update!(name: '✅ Resolved')
    billing = IssueStatus.create!(name: '💰 For Billing', is_closed: false)
    german = IssueStatus.create!(name: 'gelöst', is_closed: false)

    ids = RedmineTeamPlanning::Settings.done_status_ids
    assert_includes ids, 3, 'Resolved mit Emoji'
    assert_includes ids, billing.id, 'For Billing mit Emoji'
    assert_includes ids, german.id, 'Gelöst (deutsch, klein geschrieben)'
    assert_includes ids, 5, 'Closed (geschlossen)'
    assert_includes ids, 6, 'Rejected (geschlossen)'
    assert_not_includes ids, 1
    assert_not_includes ids, 2
    assert_not_includes ids, 4
  end

  def test_vorgabe_vergleicht_ganze_namen
    partial = IssueStatus.create!(name: 'Unresolved questions', is_closed: false)
    assert_not_includes RedmineTeamPlanning::Settings.done_status_ids, partial.id
  end

  def test_eigene_auswahl_ersetzt_die_vorgabe
    Setting.plugin_redmine_team_planning = RedmineTeamPlanning::Settings::DEFAULTS.merge('done_status_ids' => ['', '3', '5'])
    assert_equal [3, 5], RedmineTeamPlanning::Settings.done_status_ids.sort
    assert RedmineTeamPlanning::Settings.done_statuses_customized?
  end

  def test_automatisch_ignoriert_gespeicherte_auswahl
    Setting.plugin_redmine_team_planning = RedmineTeamPlanning::Settings::DEFAULTS.merge(
      'done_status_mode' => 'auto', 'done_status_ids' => ['', '1']
    )
    assert_not RedmineTeamPlanning::Settings.done_statuses_customized?
    assert_not_includes RedmineTeamPlanning::Settings.done_status_ids, 1
  end

  def test_ohne_auswahl_gilt_die_vorgabe
    Setting.plugin_redmine_team_planning = RedmineTeamPlanning::Settings::DEFAULTS.merge('done_status_ids' => [''])
    assert_not RedmineTeamPlanning::Settings.done_statuses_customized?
    assert_includes RedmineTeamPlanning::Settings.done_status_ids, 3
  end
end
