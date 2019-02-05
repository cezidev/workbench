package gpu

using import "core:math"

using import "../types"
using import "../logging"

      import odingl "../external/gl"

/*

=> GPU

General:

Meshes:
create_mesh   :: proc(vertices: []Vertex3D, indicies: []u32, name: string) -> MeshID
release_mesh  :: proc(mesh_id: MeshID)
draw_mesh     :: proc()
get_mesh_info :: proc(id: MeshID) -> (Mesh, bool)

*/

all_meshes: map[MeshID]Mesh_Info;

create_mesh :: proc(vertices: []$Vertex_Type, indicies: []u32, name: string) -> MeshID {
	static last_mesh_id: int;

	vertex_array := gen_vao();
	vertex_buffer := gen_vbo();
	index_buffer := gen_ebo();

	last_mesh_id += 1;
	id := cast(MeshID)last_mesh_id;

	mesh := Mesh_Info{name, vertex_array, vertex_buffer, index_buffer, type_info_of(Vertex_Type), len(indicies), len(vertices)};
	all_meshes[id] = mesh;

	update_mesh(id, vertices, indicies);

	return id;
}

update_mesh :: proc(id: MeshID, vertices: []$Vertex_Type, indicies: []u32) {
	mesh, ok := get_mesh_info(id);
	assert(ok);

	bind_vao(mesh.vao);

	bind_buffer(mesh.vbo);
	buffer_vertices(vertices);

	bind_buffer(mesh.ibo);
	buffer_elements(indicies);

	set_vertex_format(Vertex_Type);

	bind_vao(cast(VAO)0);

	mesh.vertex_type = type_info_of(Vertex_Type);
	mesh.index_count = len(indicies);
	mesh.vertex_count = len(vertices);
	all_meshes[id] = mesh;
}

draw_mesh :: proc(id: MeshID, mode: Draw_Mode, shader: Shader_Program, texture: Texture, color: Colorf, mvp_matrix: ^Mat4, depth_test: bool) {
	mesh, ok := get_mesh_info(id);
	assert(ok);

	bind_vao(mesh.vao);
	bind_buffer(mesh.vbo);
	bind_buffer(mesh.ibo);
	use_program(shader);
	bind_texture2d(texture);

	program := get_current_shader();

	uniform4f(program, "mesh_color", color.r, color.g, color.b, color.a);
	uniform_matrix4fv(program, "mvp_matrix", 1, false, &mvp_matrix[0][0]);

	old_depth_test := odingl.IsEnabled(odingl.DEPTH_TEST);
	defer if old_depth_test == odingl.TRUE {
		odingl.Enable(odingl.DEPTH_TEST);
	}

	if depth_test {
		odingl.Enable(odingl.DEPTH_TEST);
	}
	else {
		odingl.Disable(odingl.DEPTH_TEST);
	}

	if mesh.index_count > 0 {
		odingl.DrawElements(cast(u32)mode, i32(mesh.index_count), odingl.UNSIGNED_INT, nil);
	}
	else {
		odingl.DrawArrays(cast(u32)mode, 0, cast(i32)mesh.vertex_count);
	}
}

release_mesh :: proc(mesh_id: MeshID) {
	mesh, ok := all_meshes[mesh_id];
	assert(ok);
	delete_vao(mesh.vao);
	delete_buffer(mesh.vbo);
	delete_buffer(mesh.ibo);
	delete_key(&all_meshes, mesh_id);
}

get_mesh_info :: inline proc(id: MeshID) -> (Mesh_Info, bool) {
	mesh, ok := all_meshes[id];
	return mesh, ok;
}