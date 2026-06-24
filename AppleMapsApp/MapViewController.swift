import UIKit
import MapKit
import CoreLocation

/// Apple Maps view controller with full pan / zoom / rotate / pitch gestures,
/// map-type switching, the user's current location, and long-press pin drops.
final class MapViewController: UIViewController {

    // MARK: - Properties

    private let mapView = MKMapView()
    private let locationManager = CLLocationManager()

    private let mapTypeControl: UISegmentedControl = {
        let items = ["Standard", "Hybrid", "Satellite"]
        let control = UISegmentedControl(items: items)
        control.selectedSegmentIndex = 0
        control.translatesAutoresizingMaskIntoConstraints = false
        control.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        return control
    }()

    private lazy var recenterButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "location.fill")
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .systemBackground
        config.baseForegroundColor = .systemBlue
        let button = UIButton(configuration: config, primaryAction: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(recenterOnUser), for: .touchUpInside)
        button.accessibilityLabel = "Recenter on my location"
        return button
    }()

    private lazy var infoLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.isHidden = true
        return label
    }()

    private var didCenterOnUser = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Apple Maps"
        view.backgroundColor = .systemBackground
        setupMap()
        setupControls()
        setupLocation()
    }

    // MARK: - Setup

    private func setupMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsBuildings = true
        mapView.showsTraffic = false
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true

        // Start centered on San Francisco — a friendly default for an empty map.
        let initial = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        mapView.setRegion(MKCoordinateRegion(
            center: initial,
            latitudinalMeters: 5_000,
            longitudinalMeters: 5_000
        ), animated: false)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleMapGesture))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMapGesture))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleMapGesture))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5

        for gesture in [pinch, pan, rotate, longPress] {
            mapView.addGestureRecognizer(gesture)
        }

        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupControls() {
        mapTypeControl.addTarget(self, action: #selector(mapTypeChanged), for: .valueChanged)

        view.addSubview(mapTypeControl)
        view.addSubview(recenterButton)
        view.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            mapTypeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            mapTypeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mapTypeControl.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),

            recenterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            recenterButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            recenterButton.widthAnchor.constraint(equalToConstant: 50),
            recenterButton.heightAnchor.constraint(equalToConstant: 50),

            infoLabel.bottomAnchor.constraint(equalTo: recenterButton.topAnchor, constant: -12),
            infoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)
        ])
    }

    private func setupLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    // MARK: - Actions

    @objc private func handleMapGesture() {
        // If the user starts interacting with the map, stop trying to follow them.
        didCenterOnUser = false
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        dropPin(at: coordinate, title: "Dropped Pin", subtitle: format(coordinate: coordinate))
    }

    @objc private func mapTypeChanged() {
        switch mapTypeControl.selectedSegmentIndex {
        case 0: mapView.mapType = .standard
        case 1: mapView.mapType = .hybrid
        case 2: mapView.mapType = .satellite
        default: break
        }
    }

    @objc private func recenterOnUser() {
        guard let location = locationManager.location else {
            showInfo("Location not available yet — check Settings → Privacy → Location.")
            return
        }
        didCenterOnUser = true
        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 1_000,
            longitudinalMeters: 1_000
        )
        mapView.setRegion(region, animated: true)
    }

    // MARK: - Helpers

    private func dropPin(at coordinate: CLLocationCoordinate2D, title: String, subtitle: String) {
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        pin.title = title
        pin.subtitle = subtitle
        mapView.addAnnotation(pin)
        mapView.selectAnnotation(pin, animated: true)
    }

    private func format(coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f°, %.4f°", coordinate.latitude, coordinate.longitude)
    }

    private func showInfo(_ message: String) {
        infoLabel.text = message
        infoLabel.isHidden = false
        UIView.animate(withDuration: 0.3, delay: 2.5, options: []) {
            self.infoLabel.alpha = 0
        } completion: { _ in
            self.infoLabel.isHidden = true
            self.infoLabel.alpha = 1
        }
    }
}

// MARK: - MKMapViewDelegate

extension MapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard !(annotation is MKUserLocation) else { return nil }
        let identifier = "droppedPin"
        let view: MKMarkerAnnotationView
        if let dequeued = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView {
            dequeued.annotation = annotation
            view = dequeued
        } else {
            view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        }
        view.canShowCallout = true
        view.markerTintColor = .systemRed
        view.glyphImage = UIImage(systemName: "mappin")
        return view
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Hook for future "search this area" features.
    }
}

// MARK: - CLLocationManagerDelegate

extension MapViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            showInfo("Location access denied. The map will still work, but your position won't appear.")
        default:
            break
        }
    }
}
