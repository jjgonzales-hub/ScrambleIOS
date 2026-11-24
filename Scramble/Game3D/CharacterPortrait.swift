import SceneKit
import UIKit

/// Renders a golfer character to a small transparent image for menus.
enum CharacterPortrait {
    private static var cache: [String: UIImage] = [:]
    private static let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)

    static func image(for character: String) -> UIImage? {
        if let img = cache[character] { return img }
        let scene = SCNScene()
        let rig = GolferRig(character: character)
        rig.node.eulerAngles.y = -0.5          // three-quarter view
        scene.rootNode.addChildNode(rig.node)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 26
        cam.position = SCNVector3(0.4, 4.6, 15)
        cam.look(at: SCNVector3(0.4, 3.0, 0))
        scene.rootNode.addChildNode(cam)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1000
        key.eulerAngles = SCNVector3(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 550
        scene.rootNode.addChildNode(fill)
        scene.background.contents = UIColor.clear

        renderer.scene = scene
        renderer.pointOfView = cam
        let img = renderer.snapshot(atTime: 0, with: CGSize(width: 160, height: 160),
                                    antialiasingMode: .multisampling4X)
        cache[character] = img
        return img
    }
}
