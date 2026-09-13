require 'concurrent/atomic/semaphore'

RSpec.shared_examples :semaphore do
  let(:semaphore) { described_class.new(3) }

  describe '#initialize' do
    it 'raises an exception if the initial count is not an integer' do
      expect {
        described_class.new('foo')
      }.to raise_error(ArgumentError)
    end

    context 'when initializing with 0' do
      let(:semaphore) { described_class.new(0) }

      it do
        expect(semaphore).to_not be nil
      end
    end

    context 'when initializing with -1' do
      let(:semaphore) { described_class.new(-1) }

      it do
        semaphore.release
        expect(semaphore.available_permits).to eq 0
      end
    end
  end

  describe '#acquire' do
    context 'without block' do
      context 'permits available' do
        it 'should return nil immediately' do
          result = semaphore.acquire
          expect(result).to be_nil
        end
      end

      context 'not enough permits available' do
        it 'should block thread until permits are available' do
          semaphore.drain_permits
          in_thread { sleep(0.2); semaphore.release }

          result = semaphore.acquire
          expect(result).to be_nil
          expect(semaphore.available_permits).to eq 0
        end
      end

      context 'when acquiring negative permits' do
        it 'raises ArgumentError' do
          expect {
            semaphore.acquire(-1)
          }.to raise_error(ArgumentError)
        end
      end
    end

    context 'with block' do
      context 'permits available' do
        it 'should acquire permits, run the block, release permits, and return block return value' do
          available_permits = semaphore.available_permits
          yielded = false
          expected_result = Object.new

          actual_result = semaphore.acquire do
            expect(semaphore.available_permits).to eq(available_permits - 1)
            yielded = true
            expected_result
          end

          expect(semaphore.available_permits).to eq(available_permits)
          expect(yielded).to be true
          expect(actual_result).to be(expected_result)
        end

        it 'if the block raises, the permit is still released' do
          expect {
            expect {
              semaphore.acquire do
                raise 'boom'
              end
            }.to raise_error('boom')
          }.to_not change { semaphore.available_permits }
        end
      end

      context 'not enough permits available' do
        it 'should block thread until permits are available' do
          yielded = false
          semaphore.drain_permits
          in_thread { sleep(0.2); semaphore.release }
          expected_result = Object.new

          actual_result = semaphore.acquire do
            yielded = true
            expected_result
          end

          expect(actual_result).to be(expected_result)
          expect(yielded).to be true
          expect(semaphore.available_permits).to eq 1
        end
      end

      context 'when acquiring negative permits' do
        it 'raises ArgumentError' do
          expect {
            expect {
              semaphore.acquire(-1) do
                raise 'block should never run'
              end
            }.to raise_error(ArgumentError)
          }.not_to change { semaphore.available_permits }
        end
      end
    end
  end

  describe '#drain_permits' do
    it 'drains all available permits' do
      drained = semaphore.drain_permits
      expect(drained).to eq 3
      expect(semaphore.available_permits).to eq 0
    end

    it 'drains nothing in no permits are available' do
      semaphore.reduce_permits 3
      drained = semaphore.drain_permits
      expect(drained).to eq 0
    end
  end

  describe '#try_acquire' do
    context 'without block' do
      context 'without timeout' do
        it 'acquires immediately if permits are available' do
          result = semaphore.try_acquire(1)
          expect(result).to be_truthy
        end

        it 'returns false immediately in no permits are available' do
          result = semaphore.try_acquire(20)
          expect(result).to be_falsey
        end

        context 'when trying to acquire negative permits' do
          it do
            expect {
              semaphore.try_acquire(-1)
            }.to raise_error(ArgumentError)
          end
        end
      end

      context 'with timeout' do
        it 'acquires immediately if permits are available' do
          result = semaphore.try_acquire(1, 5)
          expect(result).to be_truthy
        end

        it 'acquires when permits are available within timeout' do
          semaphore.drain_permits
          in_thread { sleep 0.1; semaphore.release }
          result = semaphore.try_acquire(1, 1)
          expect(result).to be_truthy
        end

        it 'returns false on timeout' do
          semaphore.drain_permits
          result = semaphore.try_acquire(1, 0.1)
          expect(result).to be_falsey
        end
      end
    end

    context 'with block' do
      context 'without timeout' do
        it 'acquires immediately if permits are available and returns block return value' do
          yielded = false
          available_permits = semaphore.available_permits
          expected_result = Object.new

          actual_result = semaphore.try_acquire(1) do
            yielded = true
            expect(semaphore.available_permits).to eq(available_permits - 1)
            expected_result
          end

          expect(actual_result).to be(expected_result)
          expect(yielded).to be true
          expect(semaphore.available_permits).to eq available_permits
        end

        it 'releases permit if block raises' do
          expect {
            expect {
              semaphore.try_acquire(1) do
                raise 'boom'
              end
            }.to raise_error('boom')
          }.not_to change { semaphore.available_permits }
        end

        it 'returns false immediately in no permits are available' do
          expect {
            result = semaphore.try_acquire(20) do
              raise 'block should never run'
            end

            expect(result).to be_falsey
          }.not_to change { semaphore.available_permits }
        end

        context 'when trying to acquire negative permits' do
          it do
            expect {
              expect {
                semaphore.try_acquire(-1) do
                  raise 'block should never run'
                end
              }.to raise_error(ArgumentError)
            }.not_to change { semaphore.available_permits }
          end
        end
      end

      context 'with timeout' do
        it 'acquires immediately if permits are available, and returns block return value' do
          expect {
            yielded = false
            expected_result = Object.new

            actual_result = semaphore.try_acquire(1, 5) do
              yielded = true
              expected_result
            end

            expect(actual_result).to be(expected_result)
            expect(yielded).to be true
          }.not_to change { semaphore.available_permits }
        end

        it 'releases permits if block raises' do
          expect {
            expect {
              semaphore.try_acquire(1, 5) do
                raise 'boom'
              end
            }.to raise_error('boom')
          }.not_to change { semaphore.available_permits }
        end

        it 'acquires when permits are available within timeout, and returns block return value' do
          yielded = false
          semaphore.drain_permits
          in_thread { sleep 0.1; semaphore.release }
          expected_result = Object.new

          actual_result = semaphore.try_acquire(1, 1) do
            yielded = true
            expected_result
          end

          expect(actual_result).to be(expected_result)
          expect(yielded).to be true
          expect(semaphore.available_permits).to be 1
        end

        it 'returns false on timeout' do
          semaphore.drain_permits

          result = semaphore.try_acquire(1, 0.1) do
            raise 'block should never run'
          end

          expect(result).to be_falsey
          expect(semaphore.available_permits).to be 0
        end
      end
    end
  end

  describe '#reduce_permits' do
    it 'raises ArgumentError if reducing by negative number' do
      expect {
        semaphore.reduce_permits(-1)
      }.to raise_error(ArgumentError)
    end

    it 'reduces permits below zero' do
      semaphore.reduce_permits 1003
      expect(semaphore.available_permits).to eq(-1000)
    end

    it 'reduces permits' do
      semaphore.reduce_permits 1
      expect(semaphore.available_permits).to eq 2
      semaphore.reduce_permits 2
      expect(semaphore.available_permits).to eq 0
    end

    it 'reduces zero permits' do
      semaphore.reduce_permits 0
      expect(semaphore.available_permits).to eq 3
    end
  end

  describe '#release' do
    it 'increases the number of available permits by one' do
      semaphore.release
      expect(semaphore.available_permits).to eq 4
    end

    context 'when a number of permits is specified' do
      it 'increases the number of available permits by the specified value' do
        semaphore.release(2)
        expect(semaphore.available_permits).to eq 5
      end

      context 'when permits is set to negative number' do
        it do
          expect {
            semaphore.release(-1)
          }.to raise_error(ArgumentError)
        end
      end
    end
  end

end

# JavaSemaphore has stricter validation for zero permits and timeouts.
RSpec.shared_examples :ruby_semaphore do
  let(:semaphore) { described_class.new(3) }

  describe 'zero permits' do
    it 'acquires zero permits without changing the count' do
      expect(semaphore.acquire(0) { :acquired }).to eq :acquired
      expect(semaphore.try_acquire(0)).to be true
      expect(semaphore.release(0)).to be_nil
      expect(semaphore.available_permits).to eq 3
    end

    it 'cannot acquire zero permits while the count is negative' do
      semaphore.reduce_permits(4)
      expect(semaphore.try_acquire(0)).to be false
      expect(semaphore.try_acquire(0, 0)).to be false
    end
  end

  describe 'nonpositive timeouts' do
    it 'acquires available permits even with an expired timeout' do
      expect(semaphore.try_acquire(1, 0)).to be true
      expect(semaphore.try_acquire(1, -1)).to be true
    end

    it 'returns immediately when insufficient permits are available' do
      expect(semaphore.try_acquire(4, 0)).to be false
      expect(semaphore.try_acquire(4, -1)).to be false
      expect(semaphore.available_permits).to eq 3
    end
  end

  describe 'counts outside the native integer range' do
    it 'allows releases to grow the count beyond the upper bound' do
      maximum = Concurrent::Utility::NativeInteger::MAX_VALUE
      semaphore = described_class.new(maximum)
      expect(semaphore.release).to be_nil
      expect(semaphore.available_permits).to eq maximum + 1
      expect(semaphore.try_acquire).to be true
      expect(semaphore.available_permits).to eq maximum
      expect(semaphore.drain_permits).to eq maximum
    end

    it 'allows reductions below the lower bound and drains the negative count' do
      minimum = Concurrent::Utility::NativeInteger::MIN_VALUE
      semaphore = described_class.new(minimum)
      expect(semaphore.reduce_permits(1)).to be_nil
      expect(semaphore.available_permits).to eq minimum - 1
      expect(semaphore.try_acquire(0)).to be false
      expect(semaphore.drain_permits).to eq minimum - 1
      semaphore.release
      expect(semaphore.try_acquire(1, 0) { :acquired }).to eq :acquired
      expect(semaphore.available_permits).to eq 1
    end
  end

  describe 'argument validation' do
    [:acquire, :try_acquire, :release, :reduce_permits].each do |operation|
      it "rejects noninteger and out of range arguments to #{operation}" do
        expect { semaphore.public_send(operation, 1.5) }.to raise_error(ArgumentError)
        expect {
          semaphore.public_send(operation, Concurrent::Utility::NativeInteger::MAX_VALUE + 1)
        }.to raise_error(RangeError)
        expect(semaphore.available_permits).to eq 3
      end
    end
  end
end

module Concurrent
  RSpec.describe MutexSemaphore do
    it_should_behave_like :semaphore
    it_should_behave_like :ruby_semaphore
  end

  RSpec.describe AtomicSemaphore do
    it_should_behave_like :semaphore
    it_should_behave_like :ruby_semaphore

    let(:semaphore) { described_class.new(1) }

    it 'does not take the semaphore mutex on the fast path' do
      expect(semaphore).not_to receive(:synchronize)
      expect(semaphore.acquire).to be_nil
      expect(semaphore.try_acquire).to be false
      expect(semaphore.release).to be_nil
      expect(semaphore.try_acquire(1, 1) { :acquired }).to eq :acquired
      expect(semaphore.available_permits).to eq 1
      expect(semaphore.drain_permits).to eq 1
      expect(semaphore.reduce_permits(1)).to be_nil
    end

    it 'supports both native integer endpoints' do
      [Utility::NativeInteger::MIN_VALUE, Utility::NativeInteger::MAX_VALUE].each do |count|
        semaphore = described_class.new(count)
        expect(semaphore.available_permits).to eq count
        expect(semaphore.drain_permits).to eq count
        expect(semaphore.available_permits).to eq 0
      end
    end

    it 'accepts large updates and continues after returning to the native range' do
      maximum = Utility::NativeInteger::MAX_VALUE
      semaphore = described_class.new(0)
      semaphore.release(maximum)
      semaphore.release(maximum)
      expect(semaphore.available_permits).to eq 2 * maximum
      semaphore.acquire(maximum)
      expect(semaphore.available_permits).to eq maximum
      semaphore.reduce_permits(maximum)
      semaphore.reduce_permits(maximum)
      semaphore.reduce_permits(maximum)
      expect(semaphore.available_permits).to eq(-2 * maximum)
      expect(semaphore.drain_permits).to eq(-2 * maximum)
      semaphore.release
      expect(semaphore.acquire { :acquired }).to eq :acquired
      expect(semaphore.available_permits).to eq 1
    end

    it 'preserves every release when threads cross the upper bound' do
      maximum = Utility::NativeInteger::MAX_VALUE
      semaphore = described_class.new(maximum - 1)
      start = Queue.new
      workers = 8.times.map do
        in_thread do
          start.pop
          semaphore.release
        end
      end
      workers.size.times { start << true }
      join_with(workers)
      expect(semaphore.available_permits).to eq maximum + 7
    end

    it 'preserves every reduction when threads cross the lower bound' do
      minimum = Utility::NativeInteger::MIN_VALUE
      semaphore = described_class.new(minimum + 1)
      start = Queue.new
      workers = 8.times.map do
        in_thread do
          start.pop
          semaphore.reduce_permits(1)
        end
      end
      workers.size.times { start << true }
      join_with(workers)
      expect(semaphore.available_permits).to eq minimum - 7
    end

    [:acquire, :release, :reduce_permits, :drain_permits].each do |operation|
      it "retries a stale #{operation} CAS after promotion" do
        maximum = Utility::NativeInteger::MAX_VALUE
        semaphore = described_class.new(maximum - 1)
        counter = semaphore.instance_variable_get(:@free)
        start, paused, resume = Queue.new, Queue.new, Queue.new
        worker = nil
        intercepted = false
        allow(counter).to receive(:compare_and_set).and_wrap_original do |original, *args|
          if Thread.current == worker && !intercepted
            intercepted = true
            paused << true
            resume.pop
          end
          original.call(*args)
        end
        worker = in_thread do
          start.pop
          operation == :reduce_permits ? semaphore.reduce_permits(1) : semaphore.public_send(operation)
        end
        start << true
        paused.pop
        semaphore.release(2)
        resume << true
        join_with(worker)
        expected = { acquire: maximum, release: maximum + 2,
                     reduce_permits: maximum, drain_permits: 0 }.fetch(operation)
        expect(semaphore.available_permits).to eq expected
        expect(worker.value).to eq maximum + 1 if operation == :drain_permits
      end
    end

    it 'retries promotion when an acquisition changes the source count' do
      maximum = Utility::NativeInteger::MAX_VALUE
      semaphore = described_class.new(maximum)
      counter = semaphore.instance_variable_get(:@free)
      paused, resume = Queue.new, Queue.new
      intercepted = false
      allow(counter).to receive(:compare_and_set).and_wrap_original do |original, expected, updated|
        if updated == Utility::NativeInteger::MIN_VALUE && !intercepted
          intercepted = true
          paused << true
          resume.pop
        end
        original.call(expected, updated)
      end
      promoter = in_thread { semaphore.release }
      paused.pop
      semaphore.acquire
      resume << true
      join_with(promoter)
      expect(semaphore.available_permits).to eq maximum
      # A failed promotion must not leave a live fallback with stale permits.
      semaphore.release(2)
      expect(semaphore.available_permits).to eq maximum + 2
    end

    it 'does not overwrite an already promoted count with a stale promotion' do
      maximum = Utility::NativeInteger::MAX_VALUE
      semaphore = described_class.new(maximum)
      start, paused, resume = Queue.new, Queue.new, Queue.new
      worker = nil
      allow(semaphore).to receive(:promote_permits).and_wrap_original do |original, *args|
        if Thread.current == worker
          paused << true
          resume.pop
        end
        original.call(*args)
      end
      worker = in_thread { start.pop; semaphore.release }
      start << true
      paused.pop
      semaphore.release(2)
      resume << true
      join_with(worker)
      expect(semaphore.available_permits).to eq maximum + 3
    end

    it 'copies promoted counts without sharing their lock or updates' do
      semaphore = described_class.new(Utility::NativeInteger::MAX_VALUE)
      semaphore.release
      copy = semaphore.dup
      copy.release
      expect(copy.available_permits).to eq semaphore.available_permits + 1
      semaphore.drain_permits
      expect(copy.available_permits).to eq Utility::NativeInteger::MAX_VALUE + 2
    end

    it 'retains waiting, timeout and block cleanup after promotion' do
      semaphore = described_class.new(Utility::NativeInteger::MIN_VALUE + 1)
      waiter = in_thread do
        expect { semaphore.acquire { raise 'block failed' } }.to raise_error('block failed')
      end
      is_sleeping(waiter)
      semaphore.reduce_permits(2)
      expect(semaphore.try_acquire(1, 0.01)).to be false
      semaphore.drain_permits
      semaphore.release
      join_with(waiter)
      expect(semaphore.available_permits).to eq 1
    end

    it 'copies the permit count without sharing state or waiters' do
      waiter = in_thread { semaphore.acquire(2) }
      is_sleeping(waiter)
      copy = semaphore.dup
      expect(copy).not_to receive(:synchronize)
      copy.release
      expect(copy.available_permits).to eq 2
      expect(semaphore.available_permits).to eq 1
      semaphore.release
      join_with(waiter)
      expect(copy.available_permits).to eq 2
      expect(semaphore.available_permits).to eq 0
    end

    it 'rechecks permits released before the waiter is registered' do
      semaphore.acquire
      released = false
      allow(semaphore).to receive(:try_acquire_now).and_wrap_original do |original, permits|
        acquired = original.call(permits)
        unless acquired || released
          released = true
          semaphore.release
        end
        acquired
      end
      expect(semaphore).not_to receive(:ns_wait)
      expect(semaphore.try_acquire(1, 1)).to be true
      expect(semaphore.available_permits).to eq 0
    end

    it 'does not lose a release between the final recheck and sleeping' do
      semaphore.acquire
      resume = Queue.new
      allow(semaphore).to receive(:ns_wait).and_wrap_original do |original, timeout|
        resume.pop
        original.call(timeout)
      end

      waiter = in_thread { semaphore.try_acquire(1, 5) }
      is_sleeping(waiter)
      releaser = in_thread { semaphore.release }
      is_sleeping(releaser)
      expect(semaphore.available_permits).to eq 1
      resume << true

      expect(waiter.join(1)).not_to be_nil
      expect(waiter.value).to be true
      join_with(releaser)
      expect(semaphore.available_permits).to eq 0
    end

    it 'wakes an eligible waiter behind one requesting more permits' do
      semaphore.acquire
      large = in_thread { semaphore.acquire(2) }
      is_sleeping(large)
      small = in_thread { semaphore.acquire(1) }
      is_sleeping(small)

      semaphore.release
      expect(small.join(1)).not_to be_nil
      expect(large).to be_alive
      semaphore.release(2)
      join_with(large)
      expect(semaphore.available_permits).to eq 0
    end

    it 'retains the waiter notification when draining and reducing permits' do
      waiter = in_thread { semaphore.acquire(3) }
      is_sleeping(waiter)
      expect(semaphore.drain_permits).to eq 1
      semaphore.reduce_permits(1)
      semaphore.release(4)
      join_with(waiter)
      expect(semaphore.available_permits).to eq 0
    end

    it 'clears the waiter state after a timeout' do
      semaphore.acquire
      expect(semaphore.try_acquire(1, 0.01)).to be false
      expect(semaphore).not_to receive(:synchronize)
      semaphore.release
      expect(semaphore.available_permits).to eq 1
    end

    it 'clears the waiter state after an interrupted wait' do
      semaphore.acquire
      waiter = in_thread { semaphore.acquire }
      is_sleeping(waiter)
      waiter.kill
      join_with(waiter)
      expect(semaphore).not_to receive(:synchronize)
      semaphore.release
      expect(semaphore.available_permits).to eq 1
    end

    it 'keeps notifying other waiters when one times out' do
      semaphore.acquire
      waiter = in_thread { semaphore.acquire }
      is_sleeping(waiter)
      expect(semaphore.try_acquire(2, 0.01)).to be false
      semaphore.release
      join_with(waiter)
      expect(semaphore.available_permits).to eq 0
    end

    it 'does not oversubscribe permits under contention' do
      semaphore = described_class.new(3)
      lock = Mutex.new
      active = 0
      maximum = 0
      start = Queue.new
      workers = 8.times.map do |index|
        in_thread do
          start.pop
          100.times do
            permits = index % 3 + 1
            semaphore.acquire(permits) do
              lock.synchronize do
                active += permits
                maximum = [maximum, active].max
              end
              Thread.pass
              lock.synchronize { active -= permits }
            end
          end
        end
      end
      workers.size.times { start << true }
      join_with(workers)
      expect(maximum).to be <= 3
      expect(active).to eq 0
      expect(semaphore.available_permits).to eq 3
    end
  end

  if Concurrent.on_jruby?
    RSpec.describe JavaSemaphore do
      it_should_behave_like :semaphore
    end
  end

  RSpec.describe Semaphore do
    it_should_behave_like :semaphore
    it_should_behave_like :ruby_semaphore unless Concurrent.on_jruby?

    if Concurrent.on_jruby?
      it 'inherits from JavaSemaphore' do
        expect(Semaphore.ancestors).to include(JavaSemaphore)
      end
    elsif Concurrent.c_extensions_loaded?
      it 'inherits from AtomicSemaphore' do
        expect(Semaphore.ancestors).to include(AtomicSemaphore)
      end
    else
      it 'inherits from MutexSemaphore' do
        expect(Semaphore.ancestors).to include(MutexSemaphore)
      end
    end
  end
end
