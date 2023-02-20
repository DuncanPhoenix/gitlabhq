# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gitlab::Database::Partitioning::PartitionManager do
  include Database::PartitioningHelpers
  include ExclusiveLeaseHelpers

  let(:partitioned_table_name) { "_test_gitlab_main_my_model_example_table" }

  context 'creating partitions (mocked)' do
    subject(:sync_partitions) { described_class.new(model).sync_partitions }

    let(:model) { double(partitioning_strategy: partitioning_strategy, table_name: table, connection: connection) }
    let(:connection) { ActiveRecord::Base.connection }
    let(:table) { partitioned_table_name }
    let(:partitioning_strategy) do
      double(missing_partitions: partitions, extra_partitions: [], after_adding_partitions: nil)
    end

    let(:partitions) do
      [
        instance_double(Gitlab::Database::Partitioning::TimePartition, table: 'bar', partition_name: 'foo', to_sql: "SELECT 1"),
        instance_double(Gitlab::Database::Partitioning::TimePartition, table: 'bar', partition_name: 'foo2', to_sql: "SELECT 2")
      ]
    end

    context 'when the given table is partitioned' do
      before do
        create_partitioned_table(connection, table)

        allow(connection).to receive(:table_exists?).and_call_original
        allow(connection).to receive(:table_exists?).with(table).and_return(true)
        allow(connection).to receive(:execute).and_call_original
        expect(partitioning_strategy).to receive(:validate_and_fix)

        stub_exclusive_lease(described_class::MANAGEMENT_LEASE_KEY % table, timeout: described_class::LEASE_TIMEOUT)
      end

      it 'creates the partition' do
        expect(connection).to receive(:execute).with("LOCK TABLE \"#{table}\" IN ACCESS EXCLUSIVE MODE")
        expect(connection).to receive(:execute).with(partitions.first.to_sql)
        expect(connection).to receive(:execute).with(partitions.second.to_sql)

        sync_partitions
      end

      context 'with eplicitly provided connection' do
        let(:connection) { Ci::ApplicationRecord.connection }

        it 'uses the explicitly provided connection when any' do
          skip_if_multiple_databases_not_setup(:ci)

          expect(connection).to receive(:execute).with("LOCK TABLE \"#{table}\" IN ACCESS EXCLUSIVE MODE")
          expect(connection).to receive(:execute).with(partitions.first.to_sql)
          expect(connection).to receive(:execute).with(partitions.second.to_sql)

          described_class.new(model, connection: connection).sync_partitions
        end
      end

      context 'when an error occurs during partition management' do
        it 'does not raise an error' do
          expect(partitioning_strategy).to receive(:missing_partitions).and_raise('this should never happen (tm)')

          expect { sync_partitions }.not_to raise_error
        end
      end
    end

    context 'when the table is not partitioned' do
      let(:table) { 'this_does_not_need_to_be_real_table' }

      it 'does not try creating the partitions' do
        expect(connection).not_to receive(:execute).with("LOCK TABLE \"#{table}\" IN ACCESS EXCLUSIVE MODE")
        expect(Gitlab::AppLogger).to receive(:warn).with(
          {
            message: 'Skipping synching partitions',
            table_name: table,
            connection_name: 'main'
          }
        )

        sync_partitions
      end
    end
  end

  context 'creating partitions' do
    subject(:sync_partitions) { described_class.new(my_model).sync_partitions }

    let(:connection) { ActiveRecord::Base.connection }
    let(:my_model) do
      Class.new(ApplicationRecord) do
        include PartitionedTable

        partitioned_by :created_at, strategy: :monthly
      end
    end

    before do
      my_model.table_name = partitioned_table_name

      create_partitioned_table(connection, partitioned_table_name)
    end

    it 'creates partitions' do
      expect { sync_partitions }.to change { find_partitions(my_model.table_name, schema: Gitlab::Database::DYNAMIC_PARTITIONS_SCHEMA).size }.from(0)
    end
  end

  context 'detaching partitions (mocked)' do
    subject(:sync_partitions) { manager.sync_partitions }

    let(:manager) { described_class.new(model) }
    let(:model) { double(partitioning_strategy: partitioning_strategy, table_name: table, connection: connection) }
    let(:connection) { ActiveRecord::Base.connection }
    let(:table) { "foo" }
    let(:partitioning_strategy) do
      double(extra_partitions: extra_partitions, missing_partitions: [], after_adding_partitions: nil)
    end

    before do
      create_partitioned_table(connection, table)

      allow(connection).to receive(:table_exists?).and_call_original
      allow(connection).to receive(:table_exists?).with(table).and_return(true)
      expect(partitioning_strategy).to receive(:validate_and_fix)

      stub_exclusive_lease(described_class::MANAGEMENT_LEASE_KEY % table, timeout: described_class::LEASE_TIMEOUT)
    end

    let(:extra_partitions) do
      [
        instance_double(Gitlab::Database::Partitioning::TimePartition, table: table, partition_name: 'foo1', to_detach_sql: 'SELECT 1'),
        instance_double(Gitlab::Database::Partitioning::TimePartition, table: table, partition_name: 'foo2', to_detach_sql: 'SELECT 2')
      ]
    end

    it 'detaches each extra partition' do
      extra_partitions.each { |p| expect(manager).to receive(:detach_one_partition).with(p) }

      sync_partitions
    end

    it 'logs an error if the partitions are not detachable' do
      allow(Gitlab::Database::PostgresForeignKey).to receive(:by_referenced_table_identifier).with("public.foo")
        .and_return([double(name: "fk_1", constrained_table_identifier: "public.constrainted_table_1")])

      expect(Gitlab::AppLogger).to receive(:error).with(
        {
          message: "Failed to create / detach partition(s)",
          connection_name: "main",
          exception_class: Gitlab::Database::Partitioning::PartitionManager::UnsafeToDetachPartitionError,
          exception_message:
            "Cannot detach foo1, it would block while checking foreign key fk_1 on public.constrainted_table_1",
          table_name: "foo"
        }
      )

      sync_partitions
    end
  end

  describe '#detach_partitions' do
    around do |ex|
      travel_to(Date.parse('2021-06-23')) do
        ex.run
      end
    end

    subject { described_class.new(my_model).sync_partitions }

    let(:connection) { ActiveRecord::Base.connection }
    let(:my_model) do
      Class.new(ApplicationRecord) do
        include PartitionedTable

        partitioned_by :created_at, strategy: :monthly, retain_for: 1.month
      end
    end

    before do
      connection.execute(<<~SQL)
        CREATE TABLE #{partitioned_table_name}
        (id serial not null, created_at timestamptz not null, primary key (id, created_at))
        PARTITION BY RANGE (created_at);

        CREATE TABLE #{Gitlab::Database::DYNAMIC_PARTITIONS_SCHEMA}.#{partitioned_table_name}_202104
        PARTITION OF #{partitioned_table_name}
        FOR VALUES FROM ('2021-04-01') TO ('2021-05-01');

        CREATE TABLE #{Gitlab::Database::DYNAMIC_PARTITIONS_SCHEMA}.#{partitioned_table_name}_202105
        PARTITION OF #{partitioned_table_name}
        FOR VALUES FROM ('2021-05-01') TO ('2021-06-01');
      SQL

      my_model.table_name = partitioned_table_name

      # Also create all future partitions so that the sync is only trying to detach old partitions
      my_model.partitioning_strategy.missing_partitions.each do |p|
        connection.execute p.to_sql
      end
    end

    def num_tables
      connection.select_value(<<~SQL)
        SELECT COUNT(*)
        FROM pg_class
        where relkind IN ('r', 'p')
      SQL
    end

    it 'detaches exactly one partition' do
      expect { subject }.to change { find_partitions(my_model.table_name).size }.from(9).to(8)
    end

    it 'detaches the old partition' do
      expect { subject }.to change { has_partition(my_model, 2.months.ago.beginning_of_month) }.from(true).to(false)
    end

    it 'deletes zero tables' do
      expect { subject }.not_to change { num_tables }
    end

    it 'creates the appropriate PendingPartitionDrop entry' do
      subject

      pending_drop = Postgresql::DetachedPartition.find_by!(table_name: "#{partitioned_table_name}_202104")
      expect(pending_drop.drop_after).to eq(Time.current + described_class::RETAIN_DETACHED_PARTITIONS_FOR)
    end

    # Postgres 11 does not support foreign keys to partitioned tables
    if ApplicationRecord.database.version.to_f >= 12
      context 'when the model is the target of a foreign key' do
        before do
          connection.execute(<<~SQL)
        create unique index idx_for_fk ON #{partitioned_table_name}(created_at);

        create table _test_gitlab_main_referencing_table (
          id bigserial primary key not null,
          referencing_created_at timestamptz references #{partitioned_table_name}(created_at)
        );
          SQL
        end

        it 'does not detach partitions with a referenced foreign key' do
          expect { subject }.not_to change { find_partitions(my_model.table_name).size }
        end
      end
    end
  end

  context 'creating and then detaching partitions for a table' do
    let(:connection) { ActiveRecord::Base.connection }
    let(:my_model) do
      Class.new(ApplicationRecord) do
        include PartitionedTable

        partitioned_by :created_at, strategy: :monthly, retain_for: 1.month
      end
    end

    before do
      my_model.table_name = partitioned_table_name

      connection.execute(<<~SQL)
        CREATE TABLE #{partitioned_table_name}
        (id serial not null, created_at timestamptz not null, primary key (id, created_at))
        PARTITION BY RANGE (created_at);
      SQL
    end

    def num_partitions(model)
      find_partitions(model.table_name, schema: Gitlab::Database::DYNAMIC_PARTITIONS_SCHEMA).size
    end

    it 'creates partitions for the future then drops the oldest one after a month' do
      # 1 month for the current month, 1 month for the old month that we're retaining data for, headroom
      expected_num_partitions = (Gitlab::Database::Partitioning::MonthlyStrategy::HEADROOM + 2.months) / 1.month
      expect { described_class.new(my_model).sync_partitions }.to change { num_partitions(my_model) }.from(0).to(expected_num_partitions)

      travel 1.month

      expect { described_class.new(my_model).sync_partitions }.to change { has_partition(my_model, 2.months.ago.beginning_of_month) }.from(true).to(false).and(change { num_partitions(my_model) }.by(0))
    end
  end

  def has_partition(model, month)
    Gitlab::Database::PostgresPartition.for_parent_table(model.table_name).any? do |partition|
      Gitlab::Database::Partitioning::TimePartition.from_sql(
        model.table_name,
        partition.name,
        partition.condition
      ).from == month
    end
  end

  def create_partitioned_table(connection, table)
    connection.execute(<<~SQL)
      CREATE TABLE #{table}
      (id serial not null, created_at timestamptz not null, primary key (id, created_at))
      PARTITION BY RANGE (created_at);
    SQL
  end
end
