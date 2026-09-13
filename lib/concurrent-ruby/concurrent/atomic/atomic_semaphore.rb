require 'concurrent/atomic/atomic_fixnum'
require 'concurrent/synchronization/lockable_object'
require 'concurrent/utility/native_integer'

module Concurrent

  # @!macro semaphore
  # @!visibility private
  # @!macro internal_implementation_note
  class AtomicSemaphore < Synchronization::LockableObject

    # @free holds the permit count or this permanent marker for mutex mode.
    # In mutex mode, @large_free holds the actual count, protected by the mutex.
    MUTEX_MODE = Utility::NativeInteger::MIN_VALUE
    private_constant :MUTEX_MODE

    # @!macro semaphore_method_initialize
    def initialize(count)
      Utility::NativeInteger.ensure_integer_and_bounds count

      super()
      initialize_permits(count)
      # Atomic waiter count lets release skip locking when no waiters are registered.
      @waiters = AtomicFixnum.new(0)
      @non_unit_waiters = 0 # accessed only while holding the semaphore mutex
    end

    # @!visibility private
    def initialize_copy(other)
      super
      initialize_permits(other.available_permits)
      @waiters = AtomicFixnum.new(0)
      @non_unit_waiters = 0
    end

    # @!macro semaphore_method_acquire
    def acquire(permits = 1)
      Utility::NativeInteger.ensure_integer_and_bounds permits
      Utility::NativeInteger.ensure_positive permits

      unless try_acquire_now(permits)
        synchronize { try_acquire_timed(permits, nil) }
      end

      return unless block_given?

      begin
        yield
      ensure
        release(permits)
      end
    end

    # @!macro semaphore_method_available_permits
    def available_permits
      free = @free.value
      free == MUTEX_MODE ? synchronize { @large_free } : free
    end

    # @!macro semaphore_method_drain_permits
    def drain_permits
      while true
        free = @free.value
        if free == MUTEX_MODE
          return synchronize { @large_free.tap { @large_free = 0 } }
        end
        return free if @free.compare_and_set(free, 0)
      end
    end

    # @!macro semaphore_method_try_acquire
    def try_acquire(permits = 1, timeout = nil)
      Utility::NativeInteger.ensure_integer_and_bounds permits
      Utility::NativeInteger.ensure_positive permits

      acquired = try_acquire_now(permits)
      if !acquired && !timeout.nil?
        acquired = synchronize { try_acquire_timed(permits, timeout) }
      end

      return acquired unless block_given?
      return unless acquired

      begin
        yield
      ensure
        release(permits)
      end
    end

    # @!macro semaphore_method_release
    def release(permits = 1)
      Utility::NativeInteger.ensure_integer_and_bounds permits
      Utility::NativeInteger.ensure_positive permits

      return if permits == 0

      change_permits(permits)
      if @waiters.value > 0
        synchronize do
          # One returned permit can satisfy just one unit request. For mixed
          # requests, wake everyone so an ineligible waiter cannot leave an
          # eligible one asleep with permits still available.
          if permits == 1 && @non_unit_waiters == 0
            ns_signal
          else
            ns_broadcast
          end
        end
      end
      nil
    end

    # @!visibility private
    def reduce_permits(reduction)
      Utility::NativeInteger.ensure_integer_and_bounds reduction
      Utility::NativeInteger.ensure_positive reduction

      change_permits(-reduction)
      nil
    end

    private

    def initialize_permits(count)
      if count <= Utility::NativeInteger::MIN_VALUE || count > Utility::NativeInteger::MAX_VALUE
        @large_free = count
        @free = AtomicFixnum.new(MUTEX_MODE)
      else
        @large_free = nil
        @free = AtomicFixnum.new(count)
      end
    end

    def change_permits(delta)
      while true
        free = @free.value
        return synchronize { @large_free += delta } if free == MUTEX_MODE

        updated = free + delta
        if updated <= Utility::NativeInteger::MIN_VALUE || updated > Utility::NativeInteger::MAX_VALUE
          return if promote_permits(free, updated)
        else
          return if @free.compare_and_set(free, updated)
        end
      end
    end

    def promote_permits(expected, updated)
      synchronize do
        # A different thread may already have promoted or changed the count.
        return false unless @free.value == expected

        # Publish the fallback count before installing the marker, under the
        # same mutex used by its readers. A stale fast-path CAS then fails and
        # retries against the fallback. CAS failure leaves this value unused.
        @large_free = updated
        @free.compare_and_set(expected, MUTEX_MODE)
      end
    end

    def try_acquire_now(permits)
      while true
        free = @free.value
        if free == MUTEX_MODE
          return synchronize do
            if @large_free >= permits
              @large_free -= permits
              true
            else
              false
            end
          end
        end
        return false if free < permits
        return true if @free.compare_and_set(free, free - permits)
      end
    end

    # Called with the mutex held. Register the waiter before rechecking the
    # permits: an earlier release is seen by the recheck, and a later release
    # sees the registration and takes the mutex before notifying, after ns_wait
    # has put us to sleep. Never hold an atomic's lock while taking this mutex.
    def try_acquire_timed(permits, timeout)
      @waiters.increment
      begin
        @non_unit_waiters += 1 if permits != 1
        ns_wait_until(timeout) { try_acquire_now(permits) }
      ensure
        @non_unit_waiters -= 1 if permits != 1
        @waiters.decrement
      end
    end
  end
end
