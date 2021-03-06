# ## Schema Information
# Schema version: 20131205021701
#
# Table name: `comments`
#
# ### Columns
#
# Name                     | Type               | Attributes
# ------------------------ | ------------------ | ---------------------------
# **`comment`**            | `text`             | `default("")`
# **`commentable_id`**     | `integer`          |
# **`commentable_type`**   | `string(255)`      |
# **`created_at`**         | `datetime`         |
# **`id`**                 | `integer`          | `not null, primary key`
# **`likes_cache`**        | `integer`          | `default(0)`
# **`likes_value_cache`**  | `integer`          | `default(0)`
# **`title`**              | `string(50)`       | `default("")`
# **`updated_at`**         | `datetime`         |
# **`user_id`**            | `integer`          |
#
# ### Indexes
#
# * `index_comments_on_commentable_id`:
#     * **`commentable_id`**
# * `index_comments_on_commentable_type`:
#     * **`commentable_type`**
# * `index_comments_on_user_id`:
#     * **`user_id`**
#

class Comment < ActiveRecord::Base
  include ResqueSupport::Basic
  include ActsAsCommentable::Comment

  belongs_to :commentable, polymorphic: true
  has_many :likes, as: :likable, dependent: :destroy, after_add: :update_likes_cache, after_remove: :update_likes_cache
  after_create :generate_event
  after_save :commented_callback

  default_scope order: 'likes_cache DESC, created_at ASC'

  belongs_to :user

  alias_method :author, :user
  alias_attribute :body, :comment

  validates :comment, length: { minimum: 2 }

  def self.latest_comments_as_strings(count=5)
    Comment.unscoped.order("created_at DESC").limit(count).collect do |comment|
      "#{comment.comment} - http://coderwall.com/p/#{comment.commentable.try(:public_id)}"
    end
  end

  def commented_callback
    commentable.try(:commented)
  end

  def update_likes_cache(like)
    like.destroyed? ? decrement_likes_cache(like.value) : increment_likes_cache(like.value)
  end

  def like_by(user)
    unless self.liked_by?(user) or user.id == self.author_id
      self.likes.create!(user: user, value: user.score)
      generate_event(liker: user.username)
    end
  end

  def liked(how_much)
    unless how_much.nil?
      increment_likes_cache(how_much)
      commented_callback
    end
  end

  def liked_by?(user)
    likes.where(user_id: user.id).any?
  end

  def authored_by?(user)
    author.id == user.id
  end

  def author_id
    user_id
  end

  def mentions
    User.where(username: username_mentions)
  end

  def username_mentions
    self.body.scan(/@([a-z0-9_]+)/).flatten
  end

  def mentioned?(username)
    username_mentions.include? username
  end

  def to_commentable_public_hash
    self.commentable.try(:to_public_hash).merge(
      {
        comments: self.commentable.comments.count,
        likes:    likes.count,
      }
    )
  end

  def commenting_on_own?
    self.author_id == self.commentable.try(:user_id)
  end

  private

  def decrement_likes_cache(value)
    self.likes_cache       -= 1
    self.likes_value_cache -= value
    save(validate: false)
  end

  def increment_likes_cache(value)
    self.likes_cache       += 1
    self.likes_value_cache += value
    save(validate: false)
  end

  def generate_event(options={})
    event_type = event_type(options)
    data       = to_event_hash(options)
    enqueue(GenerateEvent, event_type, event_audience(event_type), data, 1.minute)

    if event_type == :new_comment
      Notifier.new_comment(self.commentable.try(:user).try(:username), self.author.username, self.id).deliver unless commenting_on_own?

      if (mentioned_users = self.mentions).any?
        enqueue(GenerateEvent, :comment_reply, Audience.users(mentioned_users.map(&:id)), data, 1.minute)

        mentioned_users.each do |mention|
          Notifier.comment_reply(mention.username, self.author.username, self.id).deliver
        end
      end
    end
  end

  def to_event_hash(options={})
    event_hash              = to_commentable_public_hash.merge!({ user: { username: user && user.username }, body: {} })
    event_hash[:created_at] = event_hash[:created_at].to_i

    unless options[:liker].nil?
      event_hash[:user][:username] = options[:liker]
      event_hash[:liker]           = options[:liker]
    end
    event_hash
  end

  def event_audience(event_type, options ={})
    audience = {}
    case event_type
      when :new_comment
        audience = Audience.user(self.commentable.try(:user_id))
      else
        audience = Audience.user(self.author_id)
    end
    audience
  end

  def event_type(options={})
    if options[:liker]
      :comment_like
    else
      :new_comment
    end
  end
end
