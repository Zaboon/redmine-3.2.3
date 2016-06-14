# Redmine - project management software
# Copyright (C) 2006-2016  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class IssueRelation < ActiveRecord::Base
  # Class used to represent the relations of an issue
  class Relations < Array
    include Redmine::I18n

    def initialize(issue, *args)
      @issue = issue
      super(*args)
    end

    def to_s(*args)
      map {|relation| relation.to_s(@issue)}.join(', ')
    end
  end

  belongs_to :issue_from, :class_name => 'Issue'
  belongs_to :issue_to, :class_name => 'Issue'

  TYPE_RELATES      = "relates"
  TYPE_DUPLICATES   = "duplicates"
  TYPE_DUPLICATED   = "duplicated"
  TYPE_BLOCKS       = "blocks"
  TYPE_BLOCKED      = "blocked"
  TYPE_PRECEDES     = "precedes"
  TYPE_FOLLOWS      = "follows"
  TYPE_COPIED_TO    = "copied_to"
  TYPE_COPIED_FROM  = "copied_from"

  TYPES = {
    TYPE_RELATES =>     { :name => :label_relates_to, :sym_name => :label_relates_to,
                          :order => 1, :sym => TYPE_RELATES },
    TYPE_DUPLICATES =>  { :name => :label_duplicates, :sym_name => :label_duplicated_by,
                          :order => 2, :sym => TYPE_DUPLICATED },
    TYPE_DUPLICATED =>  { :name => :label_duplicated_by, :sym_name => :label_duplicates,
                          :order => 3, :sym => TYPE_DUPLICATES, :reverse => TYPE_DUPLICATES },
    TYPE_BLOCKS =>      { :name => :label_blocks, :sym_name => :label_blocked_by,
                          :order => 4, :sym => TYPE_BLOCKED },
    TYPE_BLOCKED =>     { :name => :label_blocked_by, :sym_name => :label_blocks,
                          :order => 5, :sym => TYPE_BLOCKS, :reverse => TYPE_BLOCKS },
    TYPE_PRECEDES =>    { :name => :label_precedes, :sym_name => :label_follows,
                          :order => 6, :sym => TYPE_FOLLOWS },
    TYPE_FOLLOWS =>     { :name => :label_follows, :sym_name => :label_precedes,
                          :order => 7, :sym => TYPE_PRECEDES, :reverse => TYPE_PRECEDES },
    TYPE_COPIED_TO =>   { :name => :label_copied_to, :sym_name => :label_copied_from,
                          :order => 8, :sym => TYPE_COPIED_FROM },
    TYPE_COPIED_FROM => { :name => :label_copied_from, :sym_name => :label_copied_to,
                          :order => 9, :sym => TYPE_COPIED_TO, :reverse => TYPE_COPIED_TO }
  }.freeze

  validates_presence_of :issue_from, :issue_to, :relation_type
  validates_inclusion_of :relation_type, :in => TYPES.keys
  validates_numericality_of :delay, :allow_nil => true
  validates_uniqueness_of :issue_to_id, :scope => :issue_from_id
  validate :validate_issue_relation

  attr_protected :issue_from_id, :issue_to_id
  before_save :handle_issue_order
  after_create  :call_issues_relation_added_callback
  after_destroy :call_issues_relation_removed_callback

  def visible?(user=User.current)
    (issue_from.nil? || issue_from.visible?(user)) && (issue_to.nil? || issue_to.visible?(user))
  end

  def deletable?(user=User.current)
    visible?(user) &&
      ((issue_from.nil? || user.allowed_to?(:manage_issue_relations, issue_from.project)) ||
        (issue_to.nil? || user.allowed_to?(:manage_issue_relations, issue_to.project)))
  end

  def initialize(attributes=nil, *args)
    super
    if new_record?
      if relation_type.blank?
        self.relation_type = IssueRelation::TYPE_RELATES
      end
    end
  end

  def validate_issue_relation
    if issue_from && issue_to
      errors.add :issue_to_id, :invalid if issue_from_id == issue_to_id
      unless issue_from.project_id == issue_to.project_id ||
                Setting.cross_project_issue_relations?
        errors.add :issue_to_id, :not_same_project
      end
      # detect circular dependencies depending wether the relation should be reversed
      if TYPES.has_key?(relation_type) && TYPES[relation_type][:reverse]
        errors.add :base, :circular_dependency if issue_from.all_dependent_issues.include? issue_to
      else
        errors.add :base, :circular_dependency if issue_to.all_dependent_issues.include? issue_from
      end
      if issue_from.is_descendant_of?(issue_to) || issue_from.is_ancestor_of?(issue_to)
        errors.add :base, :cant_link_an_issue_with_a_descendant
      end
    end
  end

  def other_issue(issue)
    (self.issue_from_id == issue.id) ? issue_to : issue_from
  end

  # Returns the relation type for +issue+
  def relation_type_for(issue)
    if TYPES[relation_type]
      if self.issue_from_id == issue.id
        relation_type
      else
        TYPES[relation_type][:sym]
      end
    end
  end

  def label_for(issue)
    TYPES[relation_type] ?
        TYPES[relation_type][(self.issue_from_id == issue.id) ? :name : :sym_name] :
        :unknow
  end

  def to_s(issue=nil)
    issue ||= issue_from
    issue_text = block_given? ? yield(other_issue(issue)) : "##{other_issue(issue).try(:id)}"
    s = []
    s << l(label_for(issue))
    s << "(#{l('datetime.distance_in_words.x_days', :count => delay)})" if delay && delay != 0
    s << issue_text
    s.join(' ')
  end

  def css_classes_for(issue)
    "rel-#{relation_type_for(issue)}"
  end

  def handle_issue_order
    reverse_if_needed

    if TYPE_PRECEDES == relation_type
      self.delay ||= 0
    else
      self.delay = nil
    end
    set_issue_to_dates
  end

  def set_issue_to_dates
    soonest_start = self.successor_soonest_start
    if soonest_start && issue_to
      issue_to.reschedule_on!(soonest_start)
    end
  end

  def successor_soonest_start
    if (TYPE_PRECEDES == self.relation_type) && delay && issue_from &&
           (issue_from.start_date || issue_from.due_date)
      (issue_from.due_date || issue_from.start_date) + 1 + delay
    end
  end

  def <=>(relation)
    r = TYPES[self.relation_type][:order] <=> TYPES[relation.relation_type][:order]
    r == 0 ? id <=> relation.id : r
  end

  def init_journals(user)
    issue_from.init_journal(user) if issue_from
    issue_to.init_journal(user) if issue_to
  end

  private

  # Reverses the relation if needed so that it gets stored in the proper way
  # Should not be reversed before validation so that it can be displayed back
  # as entered on new relation form
  def reverse_if_needed
    if TYPES.has_key?(relation_type) && TYPES[relation_type][:reverse]
      issue_tmp = issue_to
      self.issue_to = issue_from
      self.issue_from = issue_tmp
      self.relation_type = TYPES[relation_type][:reverse]
    end
  end

  def call_issues_relation_added_callback
    call_issues_callback :relation_added
  end

  def call_issues_relation_removed_callback
    call_issues_callback :relation_removed
  end

  def call_issues_callback(name)
    [issue_from, issue_to].each do |issue|
      if issue
        issue.send name, self
      end
    end
  end
end
