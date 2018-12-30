module Sidekiq
  class Batch
    module Callback
      class Worker
        include Sidekiq::Worker

        def perform(clazz, event, opts, bid, parent_bid)
          return unless %w(success complete).include?(event)
          clazz, method = clazz.split("#") if (clazz && clazz.class == String && clazz.include?("#"))
          method = "on_#{event}" if method.nil?
          status = Sidekiq::Batch::Status.new(bid)

          if clazz && object = Object.const_get(clazz)
            instance = object.new
            instance.send(method, status, opts) if instance.respond_to?(method)
          end
        end
      end

      class Finalize
        def dispatch status, opts
          bid = opts["bid"]
          callback_bid = status.bid
          event = opts["event"].to_sym
          callback_batch = bid != callback_bid

          Sidekiq.logger.debug {"Finalize #{event} batch id: #{opts["bid"]}, callback batch id: #{callback_bid} callback_batch #{callback_batch}"}

          batch_status = Status.new bid
          send(event, bid, batch_status, batch_status.parent_bid)

          if callback_batch
            # Different events are run in different batches
            Sidekiq::Batch.cleanup_redis callback_bid
          end
          Sidekiq::Batch.cleanup_redis bid if event == :success
        end

        def success(bid, status, parent_bid)
          Sidekiq.logger.debug {"Finalize parent success bid: #{parent_bid}"}
          if (parent_bid)
            _, _, success, _, complete, pending, children, failure = Sidekiq.redis do |r|
              r.multi do
                r.sadd("BID-#{parent_bid}-success", bid)
                r.expire("BID-#{parent_bid}-success", Sidekiq::Batch::BID_EXPIRE_TTL)
                r.scard("BID-#{parent_bid}-success")
                r.sadd("BID-#{parent_bid}-complete", bid)
                r.scard("BID-#{parent_bid}-complete")
                r.hincrby("BID-#{parent_bid}", "pending", 0)
                r.hincrby("BID-#{parent_bid}", "children", 0)
                r.scard("BID-#{parent_bid}-failed")
              end
            end

            # if job finished successfully and parent finished successfully call parent success callback
            Batch.enqueue_callbacks(:success, parent_bid) if pending.to_i.zero? && children == success
            # if job finished successfully and parent batch completed call parent complete callback
            Batch.enqueue_callbacks(:complete, parent_bid) if complete == children && pending == failure
          end
        end

        def complete(bid, status, parent_bid)
          pending, children, success = Sidekiq.redis do |r|
            r.multi do
              r.hincrby("BID-#{bid}", "pending", 0)
              r.hincrby("BID-#{bid}", "children", 0)
              r.scard("BID-#{bid}-success")
            end
          end

          # if we batch was successful run success callback
          Batch.enqueue_callbacks(:success, bid) if pending.to_i.zero? && children == success

          # if batch was not successfull check and see if its parent is complete
          # if the parent is complete we trigger the complete callback
          # We don't want to run this if the batch was successfull because the success
          # callback may add more jobs to the batch
          if parent_bid and not (pending.to_i.zero? && children == success)
          Sidekiq.logger.debug {"Finalize parent complete bid: #{parent_bid}"}

          if (parent_bid)
            _, complete, pending, children, failure = Sidekiq.redis do |r|
              r.multi do
                r.sadd("BID-#{parent_bid}-complete", bid)
                r.scard("BID-#{parent_bid}-complete")
                r.hincrby("BID-#{parent_bid}", "pending", 0)
                r.hincrby("BID-#{parent_bid}", "children", 0)
                r.scard("BID-#{parent_bid}-failed")
              end
            end

            Batch.enqueue_callbacks(:complete, parent_bid) if complete == children && pending == failure
          end
        end
        def cleanup_redis bid, callback_bid=nil
          Sidekiq::Batch.cleanup_redis bid
          Sidekiq::Batch.cleanup_redis callback_bid if callback_bid
        end
      end
    end
  end
end
