import Foundation
import Testing
import TerminalUI
import TerminalUI3D

/// The normal of a triangle by its winding: toward the side its corners run
/// anticlockwise on.
private func faceNormal(_ mesh: Mesh, _ triangle: Mesh.Triangle) -> Vector3 {
    let first = mesh.positions[triangle.first]
    return (mesh.positions[triangle.second] - first).cross(mesh.positions[triangle.third] - first)
}

private func area(_ mesh: Mesh, _ triangle: Mesh.Triangle) -> Double {
    faceNormal(mesh, triangle).length / 2
}

/// Whether every triangle is wound to face the way its vertices' normals do.
private func windsWithItsNormals(_ mesh: Mesh) -> Bool {
    mesh.triangles.allSatisfy { triangle in
        let normals = mesh.normals[triangle.first] + mesh.normals[triangle.second] + mesh.normals[triangle.third]
        return faceNormal(mesh, triangle).dot(normals) > 0
    }
}

/// Whether every triangle of a solid round the origin faces away from it.
private func facesOutward(_ mesh: Mesh) -> Bool {
    mesh.triangles.allSatisfy { triangle in
        let centre = (mesh.positions[triangle.first] + mesh.positions[triangle.second]
                      + mesh.positions[triangle.third]) / 3
        return faceNormal(mesh, triangle).dot(centre) > 0
    }
}

@Suite("Meshes and the solids they are built into")
struct MeshTests {

    @Test func aBoxHasTwelveTrianglesFacingOut() {
        let box = Mesh.box(width: 2, height: 1, depth: 3)
        #expect(box.triangles.count == 12)
        #expect(facesOutward(box))
        #expect(windsWithItsNormals(box))
        let bounds = box.bounds
        #expect(bounds?.minimum == Vector3(-1, -0.5, -1.5))
        #expect(bounds?.maximum == Vector3(1, 0.5, 1.5))
    }

    @Test func roundSolidsFaceOutAndShadeSmooth() {
        for mesh in [Mesh.sphere(radius: 2), .cylinder(radius: 1, height: 2), .prism(sides: 6),
                     .torus(majorRadius: 2, minorRadius: 0.5)] {
            #expect(windsWithItsNormals(mesh))
        }
        #expect(facesOutward(.sphere()))
        #expect(facesOutward(.cylinder()))
        #expect(facesOutward(.prism(sides: 5)))
    }

    @Test func aSphereHasNoTrianglesAtItsPoles() {
        let sphere = Mesh.sphere(segments: 8, rings: 4)
        #expect(sphere.triangles.allSatisfy { area(sphere, $0) > 0 })
    }

    @Test func aHeightFieldIsAGridOfUpwardTrianglesTintedByHeight() {
        let heights = (0..<12).map { Double($0 % 4) }
        let ground = Mesh.heightField(columns: 4, rows: 3, spacing: 1, heights: heights)
        #expect(ground.positions.count == 12)
        #expect(ground.triangles.count == 3 * 2 * 2)
        #expect(ground.triangles.allSatisfy { faceNormal(ground, $0).y > 0 })
        #expect(ground.normals.allSatisfy { $0.y > 0 })
        #expect(ground.tints.min() == 0 && ground.tints.max() == 1)
        #expect(Mesh.heightField(columns: 4, rows: 3, heights: [1, 2]) == .empty)
    }

    @Test func lettersAreBlocksWithFacesAndSidesInTheirOwnMaterials() {
        let letter = Text3D("I", depth: 2)
        #expect(letter.height == 7)
        #expect(letter.width == Double(DotFont.glyphWidth(for: "I")))
        #expect(windsWithItsNormals(letter.mesh))
        let faces = letter.mesh.triangles.filter { $0.material == Text3D.faceMaterial }
        #expect(faces.allSatisfy { abs(letter.mesh.normals[$0.first].z) == 1 })
        let sides = letter.mesh.triangles.filter { $0.material == Text3D.sideMaterial }
        #expect(!sides.isEmpty && sides.allSatisfy { letter.mesh.normals[$0.first].z == 0 })
        let bounds = letter.mesh.bounds
        #expect(bounds?.minimum.z == -1 && bounds?.maximum.z == 1)
    }

    @Test func linesOfLetteringStackCentred() {
        let two = Text3D("AB\nC", lineSpacing: 2)
        #expect(two.height == 16)
        #expect(two.width == Text3D("AB").width)
    }

    @Test func mergingKeepsEachMeshsTriangles() {
        let merged = Mesh.cube().merged(with: Mesh.cube(material: 1).transformed(by: .translation(Vector3(3, 0, 0))))
        #expect(merged.triangles.count == 24)
        #expect(merged.triangles.filter { $0.material == 1 }.count == 12)
        #expect(merged.positions.count == Mesh.cube().positions.count * 2)
        #expect(merged.bounds?.maximum.x == 3.5)
    }

    @Test func anExtrusionRoofsItsFootprintAroundItsHole() {
        let outline = [Vector2(0, 0), Vector2(4, 0), Vector2(4, 4), Vector2(0, 4)]
        // The courtyard runs the same way as the outline: either winding
        // is taken.
        let courtyard = [Vector2(1, 1), Vector2(3, 1), Vector2(3, 3), Vector2(1, 3)]
        let building = Mesh.extrusion(of: Polygon2D(outline, holes: [courtyard]), height: 5, roofMaterial: 1)
        let roof = building.triangles.filter { triangle in
            triangle.material == 1 && building.positions[triangle.first].y == 5
        }
        let roofArea = roof.reduce(0) { $0 + area(building, $1) }
        #expect(abs(roofArea - 12) < 1e-9, "16 square units less the courtyard's 4")
        #expect(roof.allSatisfy { faceNormal(building, $0).y > 0 })
        // Four walls outside and four round the courtyard, two triangles each.
        let walls = building.triangles.filter { $0.material == 0 }
        #expect(walls.count == 16)
        #expect(walls.allSatisfy { triangle in
            let normal = faceNormal(building, triangle)
            let centre = (building.positions[triangle.first] + building.positions[triangle.third]) / 2
            let fromMiddle = Vector3(centre.x - 2, 0, centre.z - 2)
            // An outer wall faces away from the middle, a courtyard wall toward it.
            let outer = max(abs(fromMiddle.x), abs(fromMiddle.z)) > 1.5
            return outer ? normal.dot(fromMiddle) > 0 : normal.dot(fromMiddle) < 0
        })
    }

    @Test func aConcaveFootprintIsTriangulatedWithoutSpilling() {
        let ell = [Vector2(0, 0), Vector2(3, 0), Vector2(3, 1), Vector2(1, 1), Vector2(1, 3), Vector2(0, 3)]
        let block = Mesh.extrusion(of: Polygon2D(ell), height: 1, roofMaterial: 1)
        let roof = block.triangles.filter { $0.material == 1 && block.positions[$0.first].y == 1 }
        #expect(abs(roof.reduce(0) { $0 + area(block, $1) } - 5) < 1e-9)
    }

    @Test func anExtrusionStandsOnItsBase() {
        // A building part that starts above the ground, OpenMapTiles'
        // `render_min_height`: its walls run from its base to its top.
        let square = Polygon2D([Vector2(0, 0), Vector2(2, 0), Vector2(2, 2), Vector2(0, 2)])
        let part = Mesh.extrusion(of: square, height: 3, base: 4)
        let heights = part.positions.map(\.y)
        #expect(heights.min() == 4 && heights.max() == 7)
    }
}
