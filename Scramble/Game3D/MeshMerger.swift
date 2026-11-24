import SceneKit
import simd

/// Bakes many instances of small props into one geometry per material, so
/// a forest of a thousand trees costs a handful of draw calls.
///
/// SceneKit's `flattenedClone()` silently produces empty geometry for
/// USD-loaded meshes, so this reads the vertex/normal/index buffers itself.
final class MeshMerger {
    private struct Bucket {
        let material: SCNMaterial
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
    }

    private var buckets: [ObjectIdentifier: Bucket] = [:]
    private var order: [ObjectIdentifier] = []

    /// Add every mesh under `root`, transformed by its world transform
    /// (relative to the top of the tree it's in).
    func add(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let geo = node.geometry else { return }
            self.append(geo, transform: node.simdWorldTransform)
        }
    }

    private func floats(_ source: SCNGeometrySource) -> [SIMD3<Float>]? {
        guard source.usesFloatComponents, source.bytesPerComponent == 4,
              source.componentsPerVector >= 3 else { return nil }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(source.vectorCount)
        source.data.withUnsafeBytes { raw in
            for i in 0..<source.vectorCount {
                let base = source.dataOffset + i * source.dataStride
                let x = raw.load(fromByteOffset: base, as: Float.self)
                let y = raw.load(fromByteOffset: base + 4, as: Float.self)
                let z = raw.load(fromByteOffset: base + 8, as: Float.self)
                out.append(SIMD3(x, y, z))
            }
        }
        return out
    }

    private func indices(_ element: SCNGeometryElement) -> [UInt32]? {
        guard element.primitiveType == .triangles else { return nil }
        let count = element.primitiveCount * 3
        // USD-loaded meshes interleave several index channels per corner
        // (position, normal, uv…); channel 0 indexes the positions.
        let channels = max(element.indicesChannelCount, 1)
        let bpi = element.bytesPerIndex
        guard element.data.count >= count * channels * bpi else { return nil }
        var out: [UInt32] = []
        out.reserveCapacity(count)
        element.data.withUnsafeBytes { raw in
            for i in 0..<count {
                let off = i * channels * bpi
                switch bpi {
                case 1: out.append(UInt32(raw.load(fromByteOffset: off, as: UInt8.self)))
                case 2: out.append(UInt32(raw.load(fromByteOffset: off, as: UInt16.self)))
                default: out.append(raw.load(fromByteOffset: off, as: UInt32.self))
                }
            }
        }
        return out
    }

    private func append(_ geo: SCNGeometry, transform m: simd_float4x4) {
        guard let vSrc = geo.sources(for: .vertex).first, let verts = floats(vSrc) else { return }
        let worldVerts = verts.map { v -> SIMD3<Float> in
            let p = m * SIMD4(v, 1)
            return SIMD3(p.x, p.y, p.z)
        }

        for (e, element) in geo.elements.enumerated() {
            guard let idx = indices(element), !geo.materials.isEmpty else { continue }
            let material = geo.materials[e % geo.materials.count]
            let key = ObjectIdentifier(material)
            if buckets[key] == nil {
                buckets[key] = Bucket(material: material)
                order.append(key)
            }
            var bucket = buckets[key]!
            // Flat-shaded: every triangle gets its own three vertices and a
            // face normal — the crisp low-poly look, and immune to however
            // the source file stored its normals.
            var t = 0
            while t + 2 < idx.count {
                let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2])
                t += 3
                guard ia < worldVerts.count, ib < worldVerts.count, ic < worldVerts.count else { continue }
                let a = worldVerts[ia], b = worldVerts[ib], c = worldVerts[ic]
                let cr = simd_cross(b - a, c - a)
                let len = simd_length(cr)
                guard len > 1e-8 else { continue }
                let n = cr / len
                let nv = SCNVector3(n.x, n.y, n.z)
                let base = UInt32(bucket.positions.count)
                for v in [a, b, c] {
                    bucket.positions.append(SCNVector3(v.x, v.y, v.z))
                    bucket.normals.append(nv)
                }
                bucket.indices += [base, base + 1, base + 2]
            }
            buckets[key] = bucket
        }
    }

    func build() -> SCNNode {
        let root = SCNNode()
        for key in order {
            guard let b = buckets[key], !b.indices.isEmpty else { continue }
            let geo = SCNGeometry(
                sources: [SCNGeometrySource(vertices: b.positions), SCNGeometrySource(normals: b.normals)],
                elements: [SCNGeometryElement(indices: b.indices, primitiveType: .triangles)])
            geo.materials = [b.material]
            root.addChildNode(SCNNode(geometry: geo))
        }
        return root
    }
}
