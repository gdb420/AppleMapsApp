import UIKit
import MapKit
import CoreLocation

/// Apple Maps view controller with full pan / zoom / rotate / pitch gestures,
/// map-type switching, the user's current location, long-press pin drops, and
/// a bottom toolbar of explicit visual controls for each movement axis.
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

    // ----- Bottom toolbar of movement controls -----

    private let toolbar: UIVisualEffectView = {
        let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 14
        bar.layer.masksToBounds = true
        return bar
    }()

    private lazy var panUpButton    = makeArrowButton(systemName: "chevron.up",    action: #selector(panUp))
    private lazy var panDownButton  = makeArrowButton(systemName: "chevron.down",  action: #selector(panDown))
    private lazy var panLeftButton  = makeArrowButton(systemName: "chevron.left",  action: #selector(panLeft))
    private lazy var panRightButton = makeArrowButton(systemName: "chevron.right", action: #selector(panRight))

    private lazy var zoomInButton: UIButton = {
        makeSymbolButton(systemName: "plus", action: #selector(zoomIn))
    }()
    private lazy var zoomOutButton: UIButton = {
        makeSymbolButton(systemName: "minus", action: #selector(zoomOut))
    }()

    private lazy var rotateButton: UIButton = {
        let button = makeSymbolButton(systemName: "location.north.line", action: #selector(resetHeading))
        button.accessibilityLabel = "Reset heading to north"
        return button
    }()

    private lazy var pitchSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0
        slider.maximumValue = 90
        slider.value = 0
        slider.minimumTrackTintColor = .systemBlue
        slider.addTarget(self, action: #selector(pitchChanged(_:)), for: .valueChanged)
        slider.accessibilityLabel = "Camera pitch"
        return slider
    }()

    // Live camera readout
    private let cameraReadoutLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.75)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        return label
    }()

    // ----- Existing transient info label -----

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
        updateCameraReadout()

        // Keep the readout label and pitch slider in sync with every camera
        // change — gestures, programmatic moves, anything. The MKMapViewDelegate
        // hook (regionDidChangeAnimated) and the KVO observer below both call
        // updateCameraReadout() so we don't need a notification observer too.
        mapView.addObserver(self, forKeyPath: #keyPath(MKMapView.camera), options: [.new], context: nil)

        // Debug helper: launching with -flyToNYC 1 jumps straight to the 3D view
        // so the camera tilt can be verified headlessly (e.g. via simctl).
        // Use -flyToNYC 2 for a non-3D version (pitch=0) at the same location
        // for an apples-to-apples comparison.
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-flyToNYC"), idx + 1 < args.count {
            let mode = args[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                if mode == "2" {
                    let nyc = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)
                    let region = MKCoordinateRegion(
                        center: nyc,
                        latitudinalMeters: 1_500,
                        longitudinalMeters: 1_500
                    )
                    self.mapView.setRegion(region, animated: true)
                } else {
                    self.flyToNewYork()
                }
            }
        }
    }

    deinit {
        mapView.removeObserver(self, forKeyPath: #keyPath(MKMapView.camera))
        NotificationCenter.default.removeObserver(self)
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(MKMapView.camera) {
            updateCameraReadout()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    // MARK: - Setup

    private func setupMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsCompass = false   // we expose our own rotate control now
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
        view.addSubview(cameraReadoutLabel)
        view.addSubview(infoLabel)
        view.addSubview(toolbar)
        setupToolbarContents()

        NSLayoutConstraint.activate([
            mapTypeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            mapTypeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mapTypeControl.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),

            recenterButton.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12),
            recenterButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            recenterButton.widthAnchor.constraint(equalToConstant: 50),
            recenterButton.heightAnchor.constraint(equalToConstant: 50),

            cameraReadoutLabel.topAnchor.constraint(equalTo: mapTypeControl.bottomAnchor, constant: 8),
            cameraReadoutLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cameraReadoutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            cameraReadoutLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            cameraReadoutLabel.heightAnchor.constraint(equalToConstant: 22),

            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 72),

            infoLabel.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12),
            infoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)
        ])
    }

    private func setupToolbarContents() {
        // Pan pad: 3x3 grid with empty corners (Apple Maps-style).
        let panPad = UIView()
        panPad.translatesAutoresizingMaskIntoConstraints = false
        panPad.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
        panPad.layer.cornerRadius = 10
        panPad.layer.masksToBounds = true

        let panLabel = UILabel()
        panLabel.translatesAutoresizingMaskIntoConstraints = false
        panLabel.text = "Pan"
        panLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        panLabel.textColor = .secondaryLabel
        panLabel.textAlignment = .center
        panPad.addSubview(panLabel)

        for button in [panUpButton, panDownButton, panLeftButton, panRightButton] {
            panPad.addSubview(button)
        }
        NSLayoutConstraint.activate([
            panLabel.topAnchor.constraint(equalTo: panPad.topAnchor, constant: 2),
            panLabel.centerXAnchor.constraint(equalTo: panPad.centerXAnchor),

            panUpButton.topAnchor.constraint(equalTo: panLabel.bottomAnchor, constant: 2),
            panUpButton.centerXAnchor.constraint(equalTo: panPad.centerXAnchor),
            panUpButton.widthAnchor.constraint(equalToConstant: 26),
            panUpButton.heightAnchor.constraint(equalToConstant: 22),

            panDownButton.bottomAnchor.constraint(equalTo: panPad.bottomAnchor, constant: -4),
            panDownButton.centerXAnchor.constraint(equalTo: panPad.centerXAnchor),
            panDownButton.widthAnchor.constraint(equalToConstant: 26),
            panDownButton.heightAnchor.constraint(equalToConstant: 22),

            panLeftButton.leadingAnchor.constraint(equalTo: panPad.leadingAnchor, constant: 4),
            panLeftButton.centerYAnchor.constraint(equalTo: panPad.centerYAnchor),
            panLeftButton.widthAnchor.constraint(equalToConstant: 22),
            panLeftButton.heightAnchor.constraint(equalToConstant: 26),

            panRightButton.trailingAnchor.constraint(equalTo: panPad.trailingAnchor, constant: -4),
            panRightButton.centerYAnchor.constraint(equalTo: panPad.centerYAnchor),
            panRightButton.widthAnchor.constraint(equalToConstant: 22),
            panRightButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        // Vertical separators between groups.
        let sep1 = makeSeparator()
        let sep2 = makeSeparator()
        let sep3 = makeSeparator()

        // Group labels.
        let zoomLabel = makeGroupLabel("Zoom")
        let rotateLabel = makeGroupLabel("Rotate")
        let pitchLabel = makeGroupLabel("3D")

        // The rotate/pitch column gets two stacked elements (label + control).
        let rotateStack = UIStackView(arrangedSubviews: [rotateLabel, rotateButton])
        rotateStack.translatesAutoresizingMaskIntoConstraints = false
        rotateStack.axis = .vertical
        rotateStack.alignment = .center
        rotateStack.spacing = 2

        let pitchStack = UIStackView(arrangedSubviews: [pitchLabel, pitchSlider])
        pitchStack.translatesAutoresizingMaskIntoConstraints = false
        pitchStack.axis = .vertical
        pitchStack.alignment = .fill
        pitchStack.spacing = 4

        let zoomStack = UIStackView(arrangedSubviews: [zoomLabel, makeZoomRow()])
        zoomStack.translatesAutoresizingMaskIntoConstraints = false
        zoomStack.axis = .vertical
        zoomStack.alignment = .center
        zoomStack.spacing = 2

        // Top-level row: [Pan pad] [sep] [Zoom] [sep] [Rotate] [sep] [Pitch]
        let row = UIStackView(arrangedSubviews: [panPad, sep1, zoomStack, sep2, rotateStack, sep3, pitchStack])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fill
        row.spacing = 8

        toolbar.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: toolbar.contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: toolbar.contentView.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: toolbar.contentView.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: toolbar.contentView.trailingAnchor, constant: -10),

            panPad.widthAnchor.constraint(equalToConstant: 70),
            panPad.heightAnchor.constraint(equalToConstant: 60),

            sep1.widthAnchor.constraint(equalToConstant: 1),
            sep1.heightAnchor.constraint(equalToConstant: 44),
            sep2.widthAnchor.constraint(equalToConstant: 1),
            sep2.heightAnchor.constraint(equalToConstant: 44),
            sep3.widthAnchor.constraint(equalToConstant: 1),
            sep3.heightAnchor.constraint(equalToConstant: 44),

            pitchSlider.widthAnchor.constraint(equalToConstant: 110)
        ])
    }

    private func makeZoomRow() -> UIStackView {
        let row = UIStackView(arrangedSubviews: [zoomOutButton, zoomInButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fillEqually
        row.spacing = 4
        return row
    }

    private func makeArrowButton(systemName: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config, primaryAction: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        button.addTarget(self, action: action, for: .touchDownRepeat)   // hold to repeat
        return button
    }

    private func makeSymbolButton(systemName: String, action: Selector) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.image = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        config.cornerStyle = .medium
        config.baseBackgroundColor = .systemBackground
        config.baseForegroundColor = .systemBlue
        let button = UIButton(configuration: config, primaryAction: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        button.addTarget(self, action: action, for: .touchDownRepeat)   // hold to repeat
        return button
    }

    private func makeSeparator() -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
        return v
    }

    private func makeGroupLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    private func setupLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    // MARK: - Map gesture pass-through

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

    // MARK: - Existing actions

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

    // MARK: - Visual control actions

    /// Pan step in meters — 1/4 of the shorter visible dimension.
    private var panStepMeters: CLLocationDistance {
        // Use the smaller of the two visible spans.
        let span = mapView.region.span
        let metersPerDegLat = 111_000.0
        let metersPerDegLon = 111_000.0 * cos(mapView.centerCoordinate.latitude * .pi / 180.0)
        let visibleLatMeters = span.latitudeDelta * metersPerDegLat
        let visibleLonMeters = max(span.longitudeDelta * metersPerDegLon, 1)
        return min(visibleLatMeters, visibleLonMeters) / 4.0
    }

    @objc private func panUp()    { panBy(latMeters:  panStepMeters, lonMeters: 0) }
    @objc private func panDown()  { panBy(latMeters: -panStepMeters, lonMeters: 0) }
    @objc private func panLeft()  { panBy(latMeters: 0, lonMeters: -panStepMeters) }
    @objc private func panRight() { panBy(latMeters: 0, lonMeters:  panStepMeters) }

    private func panBy(latMeters: CLLocationDistance, lonMeters: CLLocationDistance) {
        // Convert meters to degrees offset, then move the camera's center.
        let center = mapView.centerCoordinate
        let dLat = latMeters / 111_000.0
        let dLon = lonMeters / (111_000.0 * cos(center.latitude * .pi / 180.0))
        let target = CLLocationCoordinate2D(
            latitude:  center.latitude  + dLat,
            longitude: center.longitude + dLon
        )
        let camera = mapView.camera.copy() as! MKMapCamera
        camera.centerCoordinate = target
        mapView.setCamera(camera, animated: true)
    }

    @objc private func zoomIn()  { zoomBy(factor: 0.5) }   // smaller altitude = closer
    @objc private func zoomOut() { zoomBy(factor: 2.0) }

    private func zoomBy(factor: Double) {
        let camera = mapView.camera.copy() as! MKMapCamera
        camera.altitude = max(50.0, min(20_000_000.0, camera.altitude * factor))
        mapView.setCamera(camera, animated: true)
    }

    @objc private func resetHeading() {
        let camera = mapView.camera.copy() as! MKMapCamera
        camera.heading = 0
        mapView.setCamera(camera, animated: true)
        showInfo("Heading reset to north (0°)")
    }

    @objc private func pitchChanged(_ slider: UISlider) {
        let camera = mapView.camera.copy() as! MKMapCamera
        // slider.value is Float, camera.pitch is CGFloat — bridge via CGFloat.
        camera.pitch = CGFloat(slider.value)
        // If the user starts tilting from a very high altitude, pull the camera in
        // so the 3D effect is actually visible.
        if camera.pitch > 0 && camera.altitude > 5_000 {
            camera.altitude = 1_500
        }
        mapView.setCamera(camera, animated: true)
    }

    // MARK: - Camera readout

    @objc private func updateCameraReadout() {
        let cam = mapView.camera
        let heading = (cam.heading.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let altitude = formatAltitude(cam.altitude)
        let text = String(
            format: "H %3.0f°   P %2.0f°   Z %@",
            heading, cam.pitch, altitude
        )
        cameraReadoutLabel.text = text
        // Keep the slider in sync with the camera (when gestures change pitch).
        // cam.pitch is CGFloat, UISlider.value is Float — convert both to Float
        // for the comparison and the assignment.
        let camPitch = Float(cam.pitch)
        if abs(pitchSlider.value - camPitch) > 0.5 {
            pitchSlider.value = camPitch
        }
    }

    private func formatAltitude(_ meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: "%.1f km", meters / 1_000)
        }
        return String(format: "%.0f m", meters)
    }

    // MARK: - 3D demo helper

    @objc private func flyToNewYork() {
        let nyc = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855) // Times Square
        let camera = MKMapCamera()
        camera.centerCoordinate = nyc
        camera.altitude = 350
        camera.pitch = 55
        camera.heading = 30
        mapView.setCamera(camera, animated: true)
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
        updateCameraReadout()
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
