# frozen_string_literal: true

class ChangedAt
  class << self
    def init(settings)
      @changed_at = settings[:changed_at_seed]
      @skip = settings[:changed_at_skip]
    end

    def make()
      changed_at = @changed_at
      @changed_at += @skip
      changed_at
    end
  end
end
