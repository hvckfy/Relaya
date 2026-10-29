import bpy, math, os
from mathutils import Vector
ROOT=os.path.dirname(os.path.abspath(__file__))
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

def material(name, color, metal, rough):
    m=bpy.data.materials.new(name); m.diffuse_color=(*color,1); m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value=(*color,1)
    p.inputs['Metallic'].default_value=metal
    p.inputs['Roughness'].default_value=rough
    return m
blue=material('Muted blue anodized aluminum',(.115,.255,.42),.58,.29)
silver=material('Satin silver',(.65,.69,.73),.72,.3)
white=material('Warm porcelain',(.82,.825,.81),.16,.32)

def rounded(w,h,r,n=32):
    pts=[]
    for cx,cy,a0 in [(w/2-r,h/2-r,0),(-w/2+r,h/2-r,90),(-w/2+r,-h/2+r,180),(w/2-r,-h/2+r,270)]:
        for j in range(n):
            a=math.radians(a0+j*90/(n-1))
            pts.append((cx+r*math.cos(a),cy+r*math.sin(a)))
    return pts

def link(name,cx,cy,w,h,r,angle,mat,zfn):
    pts=rounded(w,h,r); verts=[]; faces=[]; N=len(pts); M=16
    ca,sa=math.cos(angle),math.sin(angle)
    for i,(x,y) in enumerate(pts):
        prev=Vector(pts[(i-1)%N]); nex=Vector(pts[(i+1)%N]); tangent=(nex-prev).normalized()
        norm=Vector((tangent.y,-tangent.x))
        for j in range(M):
            a=2*math.pi*j/M
            # Broad softly rounded rectangular metal bar, not a thin wire.
            u=.145*math.copysign(abs(math.cos(a))**.6,math.cos(a))
            v=.105*math.copysign(abs(math.sin(a))**.6,math.sin(a))
            px=x+norm.x*u; py=y+norm.y*u
            X=cx+ca*px-sa*py; Y=cy+sa*px+ca*py
            verts.append((X,Y,zfn(X,Y)+v))
    for i in range(N):
        for j in range(M):
            faces.append((i*M+j,((i+1)%N)*M+j,((i+1)%N)*M+(j+1)%M,i*M+(j+1)%M))
    mesh=bpy.data.meshes.new(name); mesh.from_pydata(verts,[],faces); mesh.update()
    ob=bpy.data.objects.new(name,mesh); bpy.context.collection.objects.link(ob); ob.data.materials.append(mat)
    for p in mesh.polygons:p.use_smooth=True
    return ob

# Each part is a closed solid loop. At each pair of crossings the depth order
# reverses, so the loops are linked instead of simply stacked on one another.
link('01 - upright closed chain link',-.73,-.08,.62,2.65,.30,0,blue,lambda x,y:.80)
link('02 - upper bowl closed chain link',-.02,.50,1.78,1.20,.44,0,blue,
     lambda x,y:.80+.31*math.tanh((y-.50)*7))
link('03 - diagonal closed chain link',.43,-.71,.48,1.78,.235,math.radians(32),silver,
     lambda x,y:.80+.55*math.tanh((x-.08)*15))

pts=rounded(4.05,4.05,.78)
N=len(pts); vs=[(x,y,z) for z in [-.18,0] for x,y in pts]
fs=[tuple(reversed(range(N))),tuple(range(N,2*N))]
fs += [(i,(i+1)%N,(i+1)%N+N,i+N) for i in range(N)]
me=bpy.data.meshes.new('Tile');me.from_pydata(vs,[],fs);me.update()
ob=bpy.data.objects.new('Mac icon tile',me);bpy.context.collection.objects.link(ob);ob.data.materials.append(white)
bev=ob.modifiers.new('Soft machined edges','BEVEL');bev.width=.075;bev.segments=5
ob.modifiers.new('Weighted normals','WEIGHTED_NORMAL')

def area(name,loc,power,size):
    bpy.ops.object.light_add(type='AREA',location=loc);o=bpy.context.object;o.name=name;o.data.energy=power;o.data.shape='DISK';o.data.size=size
    o.rotation_euler=(Vector((0,0,.2))-o.location).to_track_quat('-Z','Y').to_euler()
area('Large softbox upper left',(-3,4,6),450,5)
area('Gentle fill',(4,1,5),220,4)
area('Top rim',(-1,-3,4),130,3)
bpy.ops.object.camera_add(location=(0,0,10))
camera=bpy.context.object;camera.rotation_euler=(Vector((0,0,0))-camera.location).to_track_quat('-Z','Y').to_euler()
camera.data.type='ORTHO';camera.data.ortho_scale=4.85;bpy.context.scene.camera=camera
s=bpy.context.scene;s.render.engine='CYCLES';s.cycles.samples=48;s.cycles.use_denoising=True
s.world.color=(.3,.3,.3);s.render.film_transparent=True
s.render.resolution_x=1024;s.render.resolution_y=1024;s.render.resolution_percentage=100
s.view_settings.view_transform='AgX'
s.render.image_settings.file_format='PNG';s.render.image_settings.color_mode='RGBA'
s.render.filepath=ROOT+'/relaya-chain-r-render.png'
bpy.ops.wm.save_as_mainfile(filepath=ROOT+'/relaya-chain-r.blend')
bpy.ops.render.render(write_still=True)
