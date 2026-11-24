# frozen_string_literal: true

# Team Planning – Planung in Zeiträumen (Standard eine Woche) für Redmine
#
# Jede Person plant ihren Zeitraum selbst auf einem Board (Backlog, Pool,
# laufender und kommende Zeiträume, Später, Dauerthemen), schließt ihn ab
# und schreibt einen kurzen Rückblick. Die Teamrunde zeigt alle Planungen
# nach Person oder Projekt, mit Notizen und Erinnerung per Mail.
#
# Daten liegen in eigenen Tabellen (team_planning_*); Tickets werden nur
# über Redmine geändert (Status, Zuweisung, Kommentar), mit Redmines Rechten.

Redmine::Plugin.register :redmine_team_planning do
  name 'Team Planning'
  author 'stbt.de'
  author_url 'https://stbt.de/'
  description 'Planung in Zeiträumen: Board mit Ziehen und Ablegen, Abschluss mit Rückblick, Teamrunde, Abschluss-Aktionen.'
  version '0.1.5'
  url 'https://github.com/stbt-de/redmine-team-planning'
  requires_redmine version_or_higher: '6.0.0'

  settings default: RedmineTeamPlanning::Settings::DEFAULTS, partial: 'settings/team_planning'

  # Rechte je Rolle (ohne Projektmodul: gelten, sobald jemand die Rolle in
  # einem Projekt hat)
  # Die Controller prüfen selbst (RedmineTeamPlanning::Access), weil die
  # Planung projektübergreifend ist
  permission :use_team_planning, {}, require: :member
  permission :view_others_team_planning, {}, require: :member
  permission :edit_others_team_planning, {}, require: :member

  menu :top_menu, :team_planning, { controller: 'team_planning', action: 'show' },
       caption: :label_team_planning, after: :my_page,
       if: proc { User.current.allowed_to_globally?(:use_team_planning) }
end

RedmineTeamPlanning::Hooks
# Helfer für den Block "Planung" auf Meine Seite
MyController.helper(TeamPlanningHelper)
