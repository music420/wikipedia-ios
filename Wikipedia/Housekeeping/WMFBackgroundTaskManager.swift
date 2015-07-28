//
//  WMFBackgroundTaskManager.swift
//  Wikipedia
//
//  Created by Brian Gerstle on 7/6/15.
//  Copyright (c) 2015 Wikimedia Foundation. All rights reserved.
//

import Foundation

/// Serially process items returned by a function, managing a background task for each one.
public class WMFBackgroundTaskManager<T> {
    /**
     * Function called to retrieve the next item for processing.
     * @return The next item to process, or `nil` if there aren't any items left to process.
     */
    private let next: ()->T?

    /**
     * Function called to process items.
     * @return A promise which resolves when the processing is done.
     */
    private let processor: (T) -> Promise<Void>

    /**
     * Function called when the manager stops processing tasks, e.g. to do any necessary clean up work.
     * 
     * This can be called after either:
     * - All items have been processed successfully
     * - One of the items failed to process, canceling all further processing
     * - One of the tasks' expiration handlers was invoked, canceling all further processing.
     */
    private let finalize: () -> Promise<Void>

    /**
     * Dispatch queue where all of the above functions will be invoked.
     *
     * Defaults to the global queue with "background" priority.
     */
    private let queue: dispatch_queue_t

    /**
     * Internal. Function called to resolve the promise returned by `start()`.
     * @see start()
     */
    private var resolve: (()->Void)!

    /**
     * Internal. Function called to reject the promise returned by `start()`.
     * @see start()
     */
    private var reject: ((NSError)->Void)!

    /**
     * Initialize a new background task manager with the given functions and queue.
     *
     * See documentation for the corresponding properties.
     */
    public required init(next: ()->T?,
                         processor: (T) -> Promise<Void>,
                         finalize: () -> Promise<Void>,
                         queue: dispatch_queue_t = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) {
        self.next = next
        self.processor = processor
        self.finalize = finalize
        self.queue = queue
    }

    deinit {
        if reject != nil {
            reject(NSError.cancelledError())
        }
    }

    /**
     * Start background tasks asynchronously.
     * @return A promise which will resolve when all are completed successfully or rejected in case one fails or expires.
     */
    public func start () -> Promise<Void> {
        // need to track recursion manually since promises aren't recursive
        let (promise, resolve, reject) = Promise<Void>.defer()
        self.resolve = resolve
        self.reject = reject

        // recursively process items until all are done or one fails
        dispatch_async(queue) {
            self.processNext()
        }

        let finalize = self.finalize
        return promise
        .then(on: queue, finalize)
        .recover(on: queue) { err in
            // invoke finalize, wait until it finishes, then return error
            finalize().thenInBackground() { Promise<Void>(err) }
        }
    }

    /// Process the next item returned by `next`, or resolve if `nil`.
    private func processNext() {
        if let nextItem = next() {
            return processNext(nextItem)
        } else {
            // all done!
            resolve()
        }
    }

    /// Start a background task and process `nextItem`, then invoke `processNext()` to continue recursive processing.
    private func processNext(nextItem: T) {
        let (taskPromise, resolveTask, rejectTask) = Promise<Void>.defer()
        // start a new background task, which will represent this "link" in the promise chain
        let taskId = self.dynamicType.startTask() { [weak self] in
            // if we run out of time, cancel this (and subsequent) tasks
            rejectTask(NSError.cancelledError())
        }

        // couldn't obtain valid taskID, don't process any more objects
        if taskId == UIBackgroundTaskInvalid {
            // stop immediately if we cannot get a valid task
            self.reject(NSError.cancelledError())
            return
        }

        // grab ref to polymorphic stopTask function (mocked during testing)
        let stopTask = self.dynamicType.stopTask

        // start task, propagating its state to our internal promise (which is also rejected on expiration)
        processor(nextItem)
        .thenInBackground(resolveTask)
        .catch(policy: CatchPolicy.AllErrors, rejectTask)

        taskPromise
        .finally() { () -> Void in
            // end the current background task whether we succeed or fail
            stopTask(taskId)
        }
        .then(on: queue) { [weak self] () -> Void in
            // try to continue recursively
            self?.processNext()
        }
        .catch(policy: CatchPolicy.AllErrors) { [weak self] error in
            self?.reject(error)
        }
    }

    // MARK: - Background Task Wrappers

    // XC6: @testable
    /// Create a background task (modified during testing).
    public class func startTask(expirationHandler: ()->Void) -> UIBackgroundTaskIdentifier {
        return UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler(expirationHandler)
    }

    // XC6: @testable
    /// Stop a background task (modified during testing).
    public class func stopTask(task: UIBackgroundTaskIdentifier) {
        UIApplication.sharedApplication().endBackgroundTask(task)
    }
}