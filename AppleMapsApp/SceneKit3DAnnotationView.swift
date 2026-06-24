import UIKit
import MapKit
import SceneKit

/// An MKAnnotationView that renders an arbitrary 3D model (USDZ) on top of
/// the map at the annotation's GPS coordinate. The model is rendered with
/// SceneKit, sized in points on screen, and is visible from any camera
/// angle. It auto-rotates around Y so the model looks alive, and the user
/// can drag it to a new GPS position on the map.
final class SceneKit3DAnnotationView: MKAnnotationView {

    // MARK: - Static helpers

    /// How big the model's rendering area is on screen, in points. Larger
    /// values make the model easier to see and drag, but less positionally
    /// accurate on the map.
    static let defaultSize = CGSize(width: 120, height: 120)

    // MARK: - Properties

    let sceneView = SCNView()
    private let scene = SCNScene()
    private var modelNode: SCNNode?
    private weak var mapViewRef: MKMapView?

    /// Auto-rotation around Y so the model looks "alive" even when the user
    /// isn't interacting. Disabled once the user starts dragging.
    private var autoRotateEnabled = true
    private var rotationTimer: Timer?

    /// Selection ring shown around the model when its annotation is selected.
    private let selectionRing: CAShapeLayer = {
        let ring = CAShapeLayer()
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2
        ring.isHidden = true
        return ring
    }()

    // MARK: - Init

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        frame = CGRect(origin: .zero, size: SceneKit3DAnnotationView.defaultSize)
        canShowCallout = true
        isOpaque = false
        layer.addSublayer(selectionRing)
        setupScene()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Called by MapViewController immediately after dequeueing / creating
    /// this view, so we can re-anchor ourselves when the map's region
    /// changes.
    func setMapView(_ mapView: MKMapView) {
        mapViewRef = mapView
        updatePosition()
    }

    // MARK: - SceneKit setup

    private func setupScene() {
        sceneView.frame = bounds
        sceneView.backgroundColor = .clear
        sceneView.autoenablesDefaultLighting = true
        sceneView.allowsCameraControl = false
        sceneView.antialiasingMode = .multisampling4X
        addSubview(sceneView)

        // Camera looking at the model from a slight elevation so the 3D
        // shape is visible. The model sits centered at the origin; we
        // pull the camera back and slightly above.
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 1000
        cameraNode.camera?.fieldOfView = 50
        cameraNode.position = SCNVector3(0, 1.5, 6)
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 8, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        // Ambient light so models without PBR materials still show.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 800
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Directional light for shading depth.
        let dir = SCNLight()
        dir.type = .directional
        dir.intensity = 1200
        let dirNode = SCNNode()
        dirNode.light = dir
        dirNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(dirNode)

        sceneView.scene = scene
        sceneView.pointOfView = cameraNode
    }

    private func loadUSDZModel() {
        guard let url = Bundle.main.url(forResource: "Shiba", withExtension: "usdz") else {
            print("SceneKit3DAnnotationView: Shiba.usdz not in bundle")
            return
        }
        do {
            let modelScene = try SCNScene(url: url, options: [
                .checkConsistency: true,
                .convertUnitsToMeters: true
            ])
            let container = SCNNode()
            for child in modelScene.rootNode.childNodes {
                container.addChildNode(child)
            }
            // Compute the bounding box, center it on the origin, and scale
            // it so the longest dimension is about 4 units (the camera
            // sits at z=6, so a 4-unit-wide model fills the view nicely).
            let (minVec, maxVec) = container.boundingBox
            let sx = maxVec.x - minVec.x
            let sy = maxVec.y - minVec.y
            let sz = maxVec.z - minVec.z
            let longest = max(sx, max(sy, sz))
            guard longest > 0 else { return }
            let targetSize: CGFloat = 4
            let scale = targetSize / CGFloat(longest)
            let fScale = Float(scale)
            container.scale = SCNVector3(fScale, fScale, fScale)
            // Pivot-shift: move the bounding-box center to the origin so
            // the model rotates around its own visual center.
            let cx = (minVec.x + maxVec.x) / 2 * fScale
            let cy = (minVec.y + maxVec.y) / 2 * fScale
            let cz = (minVec.z + maxVec.z) / 2 * fScale
            container.pivot = SCNMatrix4MakeTranslation(cx, cy, cz)
            container.position = SCNVector3(0, 0, 0)
            scene.rootNode.addChildNode(container)
            self.modelNode = container
            startAutoRotation()
        } catch {
            print("SceneKit3DAnnotationView: failed to load USDZ: \(error)")
        }
    }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Defer the USDZ load until we're in a window so SceneKit's GL
        // context is ready.
        if window != nil && modelNode == nil {
            loadUSDZModel()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sceneView.frame = bounds
        let inset: CGFloat = -4
        let ringRect = bounds.insetBy(dx: inset, dy: inset)
        selectionRing.path = UIBezierPath(ovalIn: ringRect).cgPath
        selectionRing.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopAutoRotation()
        autoRotateEnabled = true
        selectionRing.isHidden = true
    }

    // MARK: - Positioning

    /// Re-anchor this view so its bottom-center sits on the annotation
    /// coordinate in the map. Called by the controller on dequeue and
    /// whenever the map's region changes.
    func updatePosition() {
        guard let coord = annotation?.coordinate, let mapView = mapViewRef else { return }
        let point = mapView.convert(coord, toPointTo: mapView)
        // Anchor at the bottom-center of the view, so the model appears
        // to "stand on" the coordinate rather than float centered on it.
        layer.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        let half_h = bounds.height * 0.5
        center = CGPoint(x: point.x, y: point.y - half_h)
    }

    // MARK: - Selection

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        selectionRing.isHidden = !selected
    }

    // MARK: - Auto-rotation

    private func startAutoRotation() {
        guard autoRotateEnabled, modelNode != nil else { return }
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.modelNode?.eulerAngles.y += 0.03
        }
    }

    private func stopAutoRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    // MARK: - Drag to reposition

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        guard let mapView = mapViewRef else { return }
        switch gesture.state {
        case .began:
            autoRotateEnabled = false
            stopAutoRotation()
            isDragging = true
        case .changed:
            let translation = gesture.translation(in: mapView)
            center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
            gesture.setTranslation(.zero, in: mapView)
            let newCoord = mapView.convert(center, toCoordinateFrom: mapView)
            if let pointAnno = annotation as? MKPointAnnotation,
               (newCoord.latitude != pointAnno.coordinate.latitude ||
                newCoord.longitude != pointAnno.coordinate.longitude) {
                pointAnno.coordinate = newCoord
            }
        case .ended, .cancelled, .failed:
            isDragging = false
        default:
            break
        }
    }

    /// Public so the controller can suppress map gesture recognizers while
    /// the user is dragging a 3D object (otherwise the map also pans).
    private(set) var isDragging: Bool = false
}