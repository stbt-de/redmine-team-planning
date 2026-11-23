# frozen_string_literal: true

module RedmineTeamPlanning
  # Wer darf wessen Planung sehen und ändern?
  #
  # Eigene Planung: mit dem Recht "Team Planning nutzen". Fremde Planungen:
  # ansehen mit "Planung anderer ansehen", ändern mit "Planung anderer
  # bearbeiten" (Projektleitung). Administratoren dürfen alles.
  module Access
    module_function

    def use?(viewer)
      viewer.admin? || viewer.allowed_to_globally?(:use_team_planning)
    end

    def view?(viewer, user)
      return false unless viewer.logged?
      return use?(viewer) if viewer == user

      viewer.admin? || viewer.allowed_to_globally?(:view_others_team_planning) || edit?(viewer, user)
    end

    def edit?(viewer, user)
      return false unless viewer.logged?
      return use?(viewer) if viewer == user

      viewer.admin? || viewer.allowed_to_globally?(:edit_others_team_planning)
    end

    # Alle, die planen: aktive Benutzer mit einer Rolle, die Team Planning nutzen darf
    def team_members
      role_ids = Role.givable.select { |role| role.has_permission?(:use_team_planning) }.map(&:id)
      return User.none if role_ids.empty?

      User.active.where(id: Member.joins(:member_roles).where(member_roles: { role_id: role_ids }).select(:user_id))
          .sorted
    end
  end
end
