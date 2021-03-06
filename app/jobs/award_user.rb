class AwardUser < Struct.new(:username, :badges)
  extend ResqueSupport::Basic

  @queue = 'LOW'

  def perform
    user = User.with_username(username)

    if badges.first.is_a?(String)
      badges.map!(&:constantize)
    end

    user.check_achievements!(badges)
  end

end