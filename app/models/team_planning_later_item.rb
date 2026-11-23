# frozen_string_literal: true

# "Später": vorgemerkt, ohne festen Zeitraum
class TeamPlanningLaterItem < ApplicationRecord
  belongs_to :user
  belongs_to :issue

  validates :issue_id, uniqueness: { scope: :user_id }
end
