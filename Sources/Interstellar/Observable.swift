//
//  Observable.swift
//  Interstellar
//
//  Created by Jens Ravens on 10/12/15.
//  Copyright © 2015 nerdgeschoss GmbH. All rights reserved.
//

import Foundation

public struct ObservingOptions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    
    /// The last value of this Observable will not retained, therefore `observable.value` will always be nil.
    /// - Note: Observables without retained values can not be merged.
    public static let NoInitialValue = ObservingOptions(rawValue: 1)
    /// Observables will only fire once for an update and nil out their completion blocks afterwards. 
    /// Use this to automatically resolve retain cycles for one-off operations.
    public static let Once = ObservingOptions(rawValue: 2)
}

/**
 A type-erased Observable in order to avoid generic specification when unnecessary.
 */
public protocol Unsubscribable: class {
    func unsubscribe(_ token: ObserverToken)
}

/**
 An Observable<T> is value that will change over time.
 
 ```
 let text = Observable("World")
 
 text.subscribe { string in
    print("Hello \(string)") // prints Hello World
 }
 
 text.update("Developer") // will invoke the block and print Hello Developer
 ```
 
 Observables are thread safe.
 */

public final class Observable<T>: Unsubscribable {
    fileprivate var observers = [ObserverToken: EventSubscription<T>]()
    public private(set) var value: T?
    public let options: ObservingOptions
    fileprivate let mutex = Mutex()
    
    /// Create a new observable without a value and the desired options. You can supply a value later via `update`.
    public init(options: ObservingOptions = []) {
        self.options = options
    }
    
    /** 
    Create a new observable from a value, the type will be automatically inferred:
    
     let magicNumber = Observable(42)
    
    - Note: See observing options for various upgrades and awesome additions.
    */
    public init(_ value: T, options: ObservingOptions = []) {
        self.options = options
        if !options.contains(.NoInitialValue){
            self.value = value
        }
    }
    
    /**
    Subscribe to the future values of this observable with a block. You can use the obtained 
    `ObserverToken` to manually unsubscribe from future updates via `unsubscribe`.
     
    - Note: This block will be retained by the observable until it is deallocated or the corresponding `unsubscribe`
     function is called.
    */
    @discardableResult public func subscribe(owner: AnyObject? = nil, _ handler: @escaping (T) -> Void) -> ObserverToken {
        var token: ObserverToken!
        let observer = EventSubscription<T>(owner: owner, handler: handler)
        
        mutex.lock {
            let newHashValue = (observers.keys.map({$0.hashValue}).max() ?? -1) + 1
            token = ObserverToken(observable: self, hashValue: newHashValue)
            if !(options.contains(.Once) && value != nil) {
                observers[token] = observer
            }
            if let value = value , !options.contains(.NoInitialValue) {
                handler(value)
            }
        }
        return token
    }
    
    /// Update the inner state of an observable and notify all observers about the new value.
    public func update(_ value: T) {
        mutex.lock {
            if !options.contains(.NoInitialValue) {
                self.value = value
            }
            
            for (token, observer) in observers {
                if observer.valid() {
                    observer.handler(value)
                }
                else {
                    observers[token] = nil
                }
            }
            
            if options.contains(.Once) {
                observers.values.forEach { $0.invalidate() }
                observers.removeAll()
            }
        }
    }

    /// Unsubscribe from future updates with the token obtained from `subscribe`. This will also release the observer block.
    public func unsubscribe(_ token: ObserverToken) {
        mutex.lock {
            observers[token]?.invalidate()
            observers[token] = nil
        }
    }
    
    /**
    Merge multiple observables of the same type:
    ```
    let greeting: Observable<[String]> = Observable<[String]>.merge([Observable("Hello"), Observable("World")]) // contains ["Hello", "World"]
    ```
    - Precondition: Observables with the option .NoInitialValue do not retain their value and therefore cannot be merged.
    */
    public static func merge<U>(_ observables: [Observable<U>], options: ObservingOptions = []) -> Observable<[U]> {
        let merged = Observable<[U]>(options: options)
        let copies = observables.map { $0.map { return $0 } } // copy all observables via subscription to not retain the originals
        for observable in copies {
            precondition(!observable.options.contains(.NoInitialValue), "Event style observables do not support merging")
            observable.subscribe { value in
                let values = copies.compactMap { $0.value }
                if values.count == copies.count {
                    merged.update(values)
                }
            }
            
        }
        return merged
    }
}


extension Observable {
    /**
    Create a new observable with a transform applied:
     
     let text = Observable("Hello World")
     let uppercaseText = text.map { $0.uppercased() }
     text.update("yeah!") // uppercaseText will contain "YEAH!"
    */
    public func map<U>(_ transform: @escaping (T) -> U) -> Observable<U> {
        let observable = Observable<U>(options: options)
        subscribe { observable.update(transform($0)) }
        return observable
    }
    
    /**
    Creates a new observable with a transform applied. The value of the observable will be wrapped in a Result<T> in case the transform throws.
    */
    public func map<U>(_ transform: @escaping (T) throws -> U) -> Observable<Result<U>> {
        let observable = Observable<Result<U>>(options: options)
        subscribe { value in
            observable.update(Result(block: { return try transform(value) }))
        }
        return observable
    }
    
    /**
    Creates a new observable with a transform applied. The transform can return asynchronously by updating its returned observable.
    */
    public func flatMap<U>(_ transform: @escaping (T)->Observable<U>) -> Observable<U> {
        let observable = Observable<U>(options: options)
        subscribe { transform($0).subscribe(observable.update) }
        return observable
    }

    public func merge<U>(_ merge: Observable<U>) -> Observable<(T,U)> {
        let signal = Observable<(T,U)>()
        self.subscribe { a in
            if let b = merge.value {
                signal.update((a,b))
            }
        }
        merge.subscribe { b in
            if let a = self.value {
                signal.update((a,b))
            }
        }

        return signal
    }

    /**
     Creates a new observable which is updated with values returning true for the
     given filter function.
     */
    public func filter(_ filterFunc: @escaping (T) -> Bool) -> Observable<T> {
        let observable = Observable<T>()
        subscribe { value in
            if filterFunc(value) {
                observable.update(value)
            }
        }
        return observable
    }
}
