# frozen_string_literal: true

module RedmineTeamPlanning
  # Stylesheet und Skript auf allen Seiten (Board, Abschluss, Teamrunde und
  # der Block auf Meine Seite); beide sind klein und werden gecacht
  class Hooks < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(context = {})
      return '' unless User.current.logged?

      stylesheet_link_tag('team_planning', plugin: 'redmine_team_planning') +
        javascript_include_tag('team_planning', plugin: 'redmine_team_planning', defer: true)
    end
  end
end
