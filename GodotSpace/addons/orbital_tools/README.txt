Orbital Tools
Realistic and automatic orbital mechanics for Godot 4

Features
- Full real-time Keplerian propagation (6 classic orbital elements)
- Automatic orbit transfer using Spheres of Influence (SOI)
- Optional OrbitRender3D (toggle with a single checkbox)
- PQW (perifocal) reference frame gizmos in the 3D editor
- Global OrbitalManager singleton for easy debugging and management
- Only 2 nodes per body → hundreds of satellites with almost no overhead
- 100% compatible with Godot 4.2 • 4.3 • 4.4+

Installation (30 seconds)
1. Copy the "orbital_tools" folder into your project's res://addons/
2. Go to Project → Project Settings → Plugins → enable "Orbital Tools"
3. Go to Project → Reload Current Project (or restart the editor)
4. Done! You can now use the node.

Quick start
- Create New Node → 3D Scene → OrbitalObject3D
  (or drag orbital_object_3d.tscn from the FileSystem)
- Set the body's mass and its initial position & velocity relative to its parent attractor
- (Optional) Add an OrbitRender3D node as a sibling and enable "Show Orbit"
- That's it!

Satellites automatically change parent bodies when entering another object's Sphere of Influence.

Author: Mauri - MauxxStudio
License: MIT (free for commercial and personal projects)
Version: 1.0.0
Engine: Godot 4.2+

Thanks for using the addon! If you like it, a star is greatly appreciated ★
