# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'viewing an issue', :js, feature_category: :issue_email_participants do
  let_it_be(:user) { create(:user) }
  let_it_be(:project) { create(:project, :public) }
  let_it_be_with_refind(:issue) { create(:issue, project: project) }
  let_it_be(:note) { create(:note_on_issue, project: project, noteable: issue) }
  let_it_be(:participants) { create_list(:issue_email_participant, 4, issue: issue) }

  before do
    project.add_reporter(user)
  end

  shared_examples 'email participants warning' do |selector|
    it 'shows the correct message' do
      expect(find(selector)).to have_content(", and 1 more will be notified of your comment")
    end
  end

  shared_examples 'no email participants warning' do |selector|
    it 'does not show email participants warning' do
      expect(find(selector)).not_to have_content(", and 1 more will be notified of your comment")
    end
  end

  context 'when issue is confidential' do
    before do
      issue.update!(confidential: true)
      sign_in(user)
      visit project_issue_path(project, issue)
    end

    context 'for a new note' do
      it_behaves_like 'email participants warning', '.new-note'
    end

    context 'for a reply form' do
      before do
        find('.js-reply-button').click
      end

      it_behaves_like 'email participants warning', '.note-edit-form'
    end
  end

  context 'when issue is not confidential' do
    before do
      sign_in(user)
      visit project_issue_path(project, issue)
    end

    context 'for a new note' do
      it_behaves_like 'no email participants warning', '.new-note'
    end

    context 'for a reply form' do
      before do
        find('.js-reply-button').click
      end

      it_behaves_like 'no email participants warning', '.note-edit-form'
    end
  end
end
