# frozen_string_literal: true

# Einstellungen je Person: Länge des Zeitraums, Obergrenze an Tickets
class TeamPlanningUserSetting < ApplicationRecord
  belongs_to :user

  validates :weeks, numericality: { only_integer: true, greater_than: 0, less_than: 5 }
  validates :item_limit, numericality: { only_integer: true, greater_than: 0, less_than: 100 }

  def self.for(user)
    find_or_initialize_by(user_id: user.id)
  end
end
