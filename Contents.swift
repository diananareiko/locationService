import CoreLocation
import Foundation
import UIKit

protocol AnyLocation {
    var latitude: Double { get }
    var longitude: Double { get }

    init(_ copy: AnyLocation)
    init?(_ copy: AnyLocation?)
    init(latitude: Double, longitude: Double)
}

extension AnyLocation {

    init(_ copy: AnyLocation) {
        self.init(latitude: copy.latitude, longitude: copy.longitude)
    }

    init?(_ copy: AnyLocation?) {
        guard let copy = copy else {
            return nil
        }
        self.init(copy)
    }
    
    var locationName: String {
        "\(latitude)-\(longitude)"
    }
}

extension CLLocation: AnyLocation {

    var latitude: Double {
        coordinate.latitude
    }

    var longitude: Double {
        coordinate.longitude
    }
}

extension CLLocationCoordinate2D: AnyLocation {}


enum LocationSpace {

    struct Location: AnyLocation, Hashable {
        let latitude: Double
        let longitude: Double

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        init?(clCoordinate: CLLocationCoordinate2D?) {
            guard let clCoordinate = clCoordinate else {
                return nil
            }
            latitude = clCoordinate.latitude
            longitude = clCoordinate.longitude
        }

        init(clCoordinate: CLLocationCoordinate2D) {
            latitude = clCoordinate.latitude
            longitude = clCoordinate.longitude
        }
    }

    enum Authorization {
        case notDetermined
        case restricted
        case denied
        case authorized
    }
}

extension CLLocationCoordinate2D {
    
    init(_ coordinate: LocationSpace.Location) {
        self.init()
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}
extension LocationSpace.Authorization {

    init?(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorizedAlways,
                .authorizedWhenInUse,
                .authorized:
            self = .authorized
        @unknown default:
            return nil
        }
    }
}


protocol LocationObserver: AnyObject {
    var traits: AnyHashable { get }
    var queue: DispatchQueue { get }
    func handleUpdates(in service: LocationService)
}

extension LocationObserver {

    var queue: DispatchQueue {
        .main
    }
}

extension LocationObserver where Self: Identifiable {

    var traits: AnyHashable {
        return id
    }
}

final class LocationObserversQueue {

    private struct Wrapper {
        weak var observer: LocationObserver?
    }

    private var observers = [Wrapper]()

    func addObserver(_ observer: LocationObserver) {
        if observers.contains(where: { $0.observer?.traits == observer.traits }) {
            return
        }
        observers.append(.init(observer: observer))
        cleanUp()
    }

    func removeObserver(_ observer: LocationObserver) {
        observers.removeAll(where: { $0.observer?.traits == observer.traits })
        cleanUp()
    }

    func notify(_ service: LocationService) {
        observers.forEach {
            $0.observer?.queue.async { [weak observer = $0.observer] in
                observer?.handleUpdates(in: service)
            }
        }
    }

    private func cleanUp() {
        observers.removeAll(where: { $0.observer == nil })
    }
}

protocol LocationService: AnyObject {

    var isDetermined: Bool { get }

    var userLocation: LocationSpace.Location? { get }
    var authorizationStatus: LocationSpace.Authorization { get }

    var didAuthorize: (() -> Void)? { get set }

    func requestAuthorization()
    func requestLocation()

    func add(_ observer: LocationObserver)
    func remove(_ observer: LocationObserver)

    func startUpdatingLocation()
    func stopUpdatingLocation()
}

final class LocationServiceImp: NSObject {

    private let locationManager = CLLocationManager()
    private let observersQueue = LocationObserversQueue()

    var currentCoordinate: LocationSpace.Location? {
        if let coordinate = locationManager.location?.coordinate {
            return .init(clCoordinate: coordinate)
        }
        return nil
    }

    private(set) var userLocation: LocationSpace.Location? {
        didSet {
            observersQueue.notify(self)
        }
    }
    private(set) var authorizationStatus: LocationSpace.Authorization {
        didSet {
            observersQueue.notify(self)
        }
    }

    private(set) var currentAuthorizationStatus: CLAuthorizationStatus = .notDetermined {
        didSet {
            guard oldValue != currentAuthorizationStatus else {
                return
            }
            switch currentAuthorizationStatus {
            case .notDetermined, .denied, .restricted:
                requestAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                didAuthorize?()
            default:
                break
            }
        }
    }
    var didAuthorize: (() -> Void)?

    override init() {
        authorizationStatus = .init(locationManager.authorizationStatus) ?? .notDetermined
        userLocation = .init(clCoordinate: locationManager.location?.coordinate)
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }
}

// MARK: - LocationObserver
extension LocationServiceImp: LocationService {

    var isDetermined: Bool {
        currentCoordinate != nil
    }

    func requestLocation() {
        locationManager.requestLocation()
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func add(_ observer: LocationObserver) {
        observersQueue.addObserver(observer)
        observer.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            observer.handleUpdates(in: self)
        }
    }

    func remove(_ observer: LocationObserver) {
        observersQueue.removeObserver(observer)
    }

    func startUpdatingLocation() {
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationServiceImp: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last?.coordinate else {
            return
        }
        let userLocation = LocationSpace.Location(clCoordinate: location)
        self.userLocation = userLocation
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed location monitoring with error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        currentAuthorizationStatus = manager.authorizationStatus
        guard let status = LocationSpace.Authorization(manager.authorizationStatus) else {
            return
        }

        authorizationStatus = status
        userLocation = .init(manager.location)
    }
}


// HERE HOW TO USE


class AppLifecycleHandler: NSObject {
    private let locationService = LocationServiceImp()
    private var isUploadInProgress: Bool = false // Placeholder for upload status check logic

    override init() {
        super.init()
        // Subscribe to app lifecycle notifications
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        // Request user permission for location tracking
        requestLocationPermission()
    }

    private func requestLocationPermission() {
        locationService.requestAuthorization() // or requestWhenInUseAuthorization
    }

    @objc private func appDidEnterBackground() {
        if !isUploadInProgress {
            locationService.startUpdatingLocation()
        }
    }

    @objc private func appWillEnterForeground() {
        locationService.stopUpdatingLocation()
    }
}
