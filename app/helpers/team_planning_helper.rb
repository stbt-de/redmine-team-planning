# frozen_string_literal: true

module TeamPlanningHelper
  def format_hours(value)
    "#{format('%g', value.to_f.round(2)).tr('.', ',')} h"
  end

  def team_planning_user_param(user)
    user == User.current ? {} : { user_id: user.id }
  end

  # Personen, deren Planung der Betrachter sehen darf (eigene zuerst)
  def team_planning_people
    people = RedmineTeamPlanning::Access.team_members.select { |u| RedmineTeamPlanning::Access.view?(User.current, u) }
    people = [User.current] + (people - [User.current]) if RedmineTeamPlanning::Access.use?(User.current)
    people.uniq
  end

  def team_planning_person_select(user, url_options = {})
    options = team_planning_people.map do |person|
      label = person == User.current ? "#{person.name} (#{l(:label_team_planning_me)})" : person.name
      [label, url_for(url_options.merge(user_id: person == User.current ? nil : person.id))]
    end
    select_tag 'team_planning_user', options_for_select(options, url_for(url_options.merge(user_id: user == User.current ? nil : user.id))),
               class: 'team-planning-person', data: { navigate: true }, 'aria-label': l(:label_team_planning_person)
  end

  # Projekt-Icon aus redmine_project_icons, falls vorhanden; sonst ein Kürzel
  def team_planning_project_mark(project)
    root = project.root
    color = format('#%06x', (root.id * 2_654_435_761) % 0xFFFFFF & 0x777777)
    content_tag(:span, root.name.to_s.first.upcase, class: 'tp-picon', style: "background-color: #{color}",
                                                    title: project.name, 'aria-hidden': true)
  end

  def team_planning_status_class(issue, planner)
    return 'is-done' if planner.done_status_ids.include?(issue.status_id)

    "status-#{issue.status_id}"
  end

  def team_planning_result_label(result)
    l(:"label_team_planning_result_#{result}") if result.present?
  end

  def team_planning_people_count(count)
    count == 1 ? l(:label_team_planning_day_one) : l(:label_team_planning_days, count: count)
  end
end
