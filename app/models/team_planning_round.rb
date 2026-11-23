# frozen_string_literal: true

# Teamrunde an einem Tag: Notizen für Themen, die zu keiner Person gehören
class TeamPlanningRound < ApplicationRecord
  validates :held_on, presence: true, uniqueness: true

  def self.for(date)
    find_or_initialize_by(held_on: date)
  end
end
