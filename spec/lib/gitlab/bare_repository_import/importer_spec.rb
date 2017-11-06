require 'spec_helper'

describe Gitlab::BareRepositoryImport::Importer, repository: true do
  let!(:admin) { create(:admin) }
  let(:bare_repository) { Gitlab::BareRepositoryImport::Repository.new(TestEnv.repos_path, File.join(TestEnv.repos_path, "#{project_path}.git")) }

  subject(:importer) { described_class.new(bare_repository) }

  before do
    allow(described_class).to receive(:log)
    allow_any_instance_of(described_class).to receive(:import_repo).and_return(true)
  end

  shared_examples 'importing a repository' do
    describe '.execute' do
      it 'creates a project for a repository in storage' do
        FileUtils.mkdir_p(File.join(TestEnv.repos_path, "#{project_path}.git"))
        fake_importer = double

        expect(described_class).to receive(:new).and_return(fake_importer)
        expect(fake_importer).to receive(:create_project_if_needed)

        described_class.execute(TestEnv.repos_path)
      end

      it 'skips wiki repos' do
        FileUtils.mkdir_p(File.join(TestEnv.repos_path, 'the-group', 'the-project.wiki.git'))

        expect(described_class).to receive(:log).with(' * Skipping wiki repo')
        expect(described_class).not_to receive(:new)

        described_class.execute(TestEnv.repos_path)
      end
    end

    describe '#initialize' do
      context 'without admin users' do
        let(:admin) { nil }

        it 'raises an error' do
          expect { importer }.to raise_error(Gitlab::BareRepositoryImport::Importer::NoAdminError)
        end
      end
    end

    describe '#create_project_if_needed' do
      it 'starts an import for a project that did not exist' do
        expect(importer).to receive(:create_project)

        importer.create_project_if_needed
      end

      it 'skips importing when the project already exists' do
        project = create(:project, path: 'a-project', namespace: existing_group)

        expect(importer).not_to receive(:create_project)
        expect(importer).to receive(:log).with(" * #{project.name} (#{project_path}) exists")

        importer.create_project_if_needed
      end

      it 'creates a project with the correct path in the database' do
        importer.create_project_if_needed

        expect(Project.find_by_full_path(project_path)).not_to be_nil
      end

      context 'hashed storage enabled' do
        it 'creates a project with the correct path in the database' do
          stub_application_setting(hashed_storage_enabled: true)

          importer.create_project_if_needed

          expect(Project.find_by_full_path(project_path)).not_to be_nil
        end
      end
    end
  end

  context 'with subgroups', :nested_groups do
    let(:project_path) { 'a-group/a-sub-group/a-project' }

    let(:existing_group) do
      group = create(:group, path: 'a-group')
      create(:group, path: 'a-sub-group', parent: group)
    end

    it_behaves_like 'importing a repository'
  end

  context 'without subgroups' do
    let(:project_path) { 'a-group/a-project' }
    let(:existing_group) { create(:group, path: 'a-group') }

    it_behaves_like 'importing a repository'
  end

  context 'when subgroups are not available' do
    let(:project_path) { 'a-group/a-sub-group/a-project' }

    before do
      expect(Group).to receive(:supports_nested_groups?) { false }
    end

    describe '#create_project_if_needed' do
      it 'raises an error' do
        expect { importer.create_project_if_needed }.to raise_error('Nested groups are not supported on MySQL')
      end
    end
  end
end
