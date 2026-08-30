# Intersection

- `object` — The Mesh that was hit. Null only for a node this script did not build — one opened
  from the command line.
- `name` — Its name, which identifies it even when object is null.
- `distance` — World units along the ray. Comparable across objects however each of them is
  scaled.
- `point` — Where the ray met the surface, world space, as a Vector3.
- `normal` — The surface normal there, world space, unit length.
