# frozen_string_literal: true

require File.expand_path('../../../test/test_helper', __dir__)

module RedmineTeamPlanning
  module TestHelper
    FIXTURES = %i[
      projects users email_addresses user_preferences members member_roles roles
      issues issue_statuses trackers projects_trackers enabled_modules enumerations
      time_entries issue_categories versions workflows groups_users custom_fields custom_values
      custom_fields_projects custom_fields_trackers
    ].freeze

    MONDAY = Date.new(2026, 11, 23) # KW 48

    def setup_team_planning
      Setting.plugin_redmine_team_planning = RedmineTeamPlanning::Settings::DEFAULTS.dup
      Role.find(1).add_permission!(:use_team_planning, :view_others_team_planning, :edit_others_team_planning) # Manager
      Role.find(2).add_permission!(:use_team_planning, :view_others_team_planning) # Developer
      @jsmith = User.find(2)   # Manager in Projekt 1
      @dlopper = User.find(3)  # Developer in Projekt 1
      @project = Project.find(1)
    end

    def planner_for(user, viewer = user, today: MONDAY + 2)
      RedmineTeamPlanning::Planner.new(user, viewer, today: today)
    end

    def create_issue(assigned_to: nil, project: @project, status: IssueStatus.find(1), subject: nil, **attributes)
      issue = Issue.create!({ project: project, tracker: project.trackers.first, author: User.find(2),
                              subject: subject || "Testticket #{SecureRandom.hex(3)}", status: status,
                              priority: IssuePriority.default || IssuePriority.first }.merge(attributes))
      Issue.where(id: issue.id).update_all(assigned_to_id: assigned_to&.id)
      Issue.find(issue.id)
    end

    def log_time(user, issue, hours, spent_on)
      TimeEntry.create!(project: issue.project, issue: issue, user: user, author: user, hours: hours, spent_on: spent_on,
                        activity: TimeEntryActivity.shared.active.first)
    end

    def location_ids(planner, location)
      case location
      when 'standing' then planner.standings.map(&:issue_id)
      when 'later' then planner.later_items.map(&:issue_id)
      else planner.items(planner.period_for(location)).map(&:issue_id)
      end
    end
  end
end
