// Compatibility proxy for the FFmpeg 6.1 avformat build used by PICO Cast.
//
// The project originally shipped an early libavcodec 60 build. FFmpeg 6.1's
// avformat imports three packet-side-data helpers that were added later in the
// same ABI major. This DLL forwards every existing codec symbol to the original
// avcodec-60.dll and backports only those helpers. The implementation follows
// FFmpeg's LGPL-licensed libavcodec/avpacket.c.

#include <windows.h>

#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstring>

#define FORWARD_TO_AVCODEC(symbol) \
	__pragma(comment(linker, "/export:" #symbol "=\"avcodec-60." #symbol "\""))

FORWARD_TO_AVCODEC(av_ac3_parse_header)
FORWARD_TO_AVCODEC(av_adts_header_parse)
FORWARD_TO_AVCODEC(av_bsf_alloc)
FORWARD_TO_AVCODEC(av_bsf_flush)
FORWARD_TO_AVCODEC(av_bsf_free)
FORWARD_TO_AVCODEC(av_bsf_get_by_name)
FORWARD_TO_AVCODEC(av_bsf_get_null_filter)
FORWARD_TO_AVCODEC(av_bsf_init)
FORWARD_TO_AVCODEC(av_bsf_list_parse_str)
FORWARD_TO_AVCODEC(av_bsf_receive_packet)
FORWARD_TO_AVCODEC(av_bsf_send_packet)
FORWARD_TO_AVCODEC(av_codec_is_decoder)
FORWARD_TO_AVCODEC(av_codec_iterate)
FORWARD_TO_AVCODEC(av_cpb_properties_alloc)
FORWARD_TO_AVCODEC(av_dirac_parse_sequence_header)
FORWARD_TO_AVCODEC(av_dv_codec_profile2)
FORWARD_TO_AVCODEC(av_dv_frame_profile)
FORWARD_TO_AVCODEC(av_get_audio_frame_duration)
FORWARD_TO_AVCODEC(av_get_audio_frame_duration2)
FORWARD_TO_AVCODEC(av_get_bits_per_sample)
FORWARD_TO_AVCODEC(av_get_exact_bits_per_sample)
FORWARD_TO_AVCODEC(av_grow_packet)
FORWARD_TO_AVCODEC(av_init_packet)
FORWARD_TO_AVCODEC(av_new_packet)
FORWARD_TO_AVCODEC(av_packet_add_side_data)
FORWARD_TO_AVCODEC(av_packet_alloc)
FORWARD_TO_AVCODEC(av_packet_clone)
FORWARD_TO_AVCODEC(av_packet_copy_props)
FORWARD_TO_AVCODEC(av_packet_free)
FORWARD_TO_AVCODEC(av_packet_from_data)
FORWARD_TO_AVCODEC(av_packet_get_side_data)
FORWARD_TO_AVCODEC(av_packet_make_refcounted)
FORWARD_TO_AVCODEC(av_packet_make_writable)
FORWARD_TO_AVCODEC(av_packet_move_ref)
FORWARD_TO_AVCODEC(av_packet_new_side_data)
FORWARD_TO_AVCODEC(av_packet_pack_dictionary)
FORWARD_TO_AVCODEC(av_packet_ref)
FORWARD_TO_AVCODEC(av_packet_rescale_ts)
FORWARD_TO_AVCODEC(av_packet_unref)
FORWARD_TO_AVCODEC(av_parser_close)
FORWARD_TO_AVCODEC(av_parser_init)
FORWARD_TO_AVCODEC(av_parser_parse2)
FORWARD_TO_AVCODEC(av_shrink_packet)
FORWARD_TO_AVCODEC(av_vorbis_parse_frame_flags)
FORWARD_TO_AVCODEC(av_vorbis_parse_free)
FORWARD_TO_AVCODEC(av_vorbis_parse_init)
FORWARD_TO_AVCODEC(av_vorbis_parse_reset)
FORWARD_TO_AVCODEC(av_xiphlacing)
FORWARD_TO_AVCODEC(avcodec_alloc_context3)
FORWARD_TO_AVCODEC(avcodec_close)
FORWARD_TO_AVCODEC(avcodec_decode_subtitle2)
FORWARD_TO_AVCODEC(avcodec_descriptor_get)
FORWARD_TO_AVCODEC(avcodec_descriptor_get_by_name)
FORWARD_TO_AVCODEC(avcodec_find_decoder)
FORWARD_TO_AVCODEC(avcodec_find_decoder_by_name)
FORWARD_TO_AVCODEC(avcodec_free_context)
FORWARD_TO_AVCODEC(avcodec_get_name)
FORWARD_TO_AVCODEC(avcodec_get_type)
FORWARD_TO_AVCODEC(avcodec_is_open)
FORWARD_TO_AVCODEC(avcodec_open2)
FORWARD_TO_AVCODEC(avcodec_parameters_alloc)
FORWARD_TO_AVCODEC(avcodec_parameters_copy)
FORWARD_TO_AVCODEC(avcodec_parameters_free)
FORWARD_TO_AVCODEC(avcodec_parameters_from_context)
FORWARD_TO_AVCODEC(avcodec_parameters_to_context)
FORWARD_TO_AVCODEC(avcodec_pix_fmt_to_codec_tag)
FORWARD_TO_AVCODEC(avcodec_receive_frame)
FORWARD_TO_AVCODEC(avcodec_send_packet)
FORWARD_TO_AVCODEC(avcodec_string)
FORWARD_TO_AVCODEC(avpriv_ac3_parse_header)
FORWARD_TO_AVCODEC(avpriv_adts_header_parse)
FORWARD_TO_AVCODEC(avpriv_codec_get_cap_skip_frame_fill_param)
FORWARD_TO_AVCODEC(avpriv_dca_convert_bitstream)
FORWARD_TO_AVCODEC(avpriv_dca_parse_core_frame_header)
FORWARD_TO_AVCODEC(avpriv_exif_decode_ifd)
FORWARD_TO_AVCODEC(avpriv_find_start_code)
FORWARD_TO_AVCODEC(avpriv_h264_has_num_reorder_frames)
FORWARD_TO_AVCODEC(avpriv_mpeg4audio_get_config2)
FORWARD_TO_AVCODEC(avpriv_mpegaudio_decode_header)
FORWARD_TO_AVCODEC(avpriv_packet_list_free)
FORWARD_TO_AVCODEC(avpriv_packet_list_get)
FORWARD_TO_AVCODEC(avpriv_packet_list_put)
FORWARD_TO_AVCODEC(avpriv_pix_fmt_find)
FORWARD_TO_AVCODEC(avpriv_split_xiph_headers)
FORWARD_TO_AVCODEC(avpriv_tak_parse_streaminfo)
FORWARD_TO_AVCODEC(avsubtitle_free)

#undef FORWARD_TO_AVCODEC

namespace {

constexpr std::size_t INPUT_BUFFER_PADDING_SIZE = 64;

struct PacketSideData {
	std::uint8_t *data;
	std::size_t size;
	int type;
};

using AvMalloc = void *(__cdecl *)(std::size_t);
using AvReallocArray = void *(__cdecl *)(void *, std::size_t, std::size_t);
using AvFree = void (__cdecl *)(void *);

struct AvutilApi {
	AvMalloc malloc_fn = nullptr;
	AvReallocArray realloc_array_fn = nullptr;
	AvFree free_fn = nullptr;

	bool is_valid() const {
		return malloc_fn != nullptr && realloc_array_fn != nullptr && free_fn != nullptr;
	}
};

AvutilApi load_avutil_api() {
	HMODULE module = GetModuleHandleW(L"avutil-58.dll");
	if (module == nullptr) {
		module = LoadLibraryW(L"avutil-58.dll");
	}
	if (module == nullptr) {
		return {};
	}
	return {
		reinterpret_cast<AvMalloc>(GetProcAddress(module, "av_malloc")),
		reinterpret_cast<AvReallocArray>(GetProcAddress(module, "av_realloc_array")),
		reinterpret_cast<AvFree>(GetProcAddress(module, "av_free")),
	};
}

AvutilApi &avutil_api() {
	static AvutilApi api = load_avutil_api();
	return api;
}

PacketSideData *packet_side_data_add(
		PacketSideData **side_data,
		int *side_data_count,
		int type,
		void *data,
		std::size_t size) {
	if (side_data == nullptr || side_data_count == nullptr || *side_data_count < 0) {
		return nullptr;
	}
	AvutilApi &api = avutil_api();
	if (!api.is_valid()) {
		return nullptr;
	}

	PacketSideData *entries = *side_data;
	const int count = *side_data_count;
	for (int index = 0; index < count; ++index) {
		if (entries[index].type != type) {
			continue;
		}
		api.free_fn(entries[index].data);
		entries[index].data = static_cast<std::uint8_t *>(data);
		entries[index].size = size;
		return &entries[index];
	}
	if (count == INT_MAX) {
		return nullptr;
	}

	auto *resized = static_cast<PacketSideData *>(
		api.realloc_array_fn(entries, static_cast<std::size_t>(count) + 1, sizeof(PacketSideData))
	);
	if (resized == nullptr) {
		return nullptr;
	}
	*side_data = resized;
	resized[count].data = static_cast<std::uint8_t *>(data);
	resized[count].size = size;
	resized[count].type = type;
	*side_data_count = count + 1;
	return &resized[count];
}

} // namespace

extern "C" __declspec(dllexport) PacketSideData *__cdecl av_packet_side_data_add(
		PacketSideData **side_data,
		int *side_data_count,
		int type,
		void *data,
		std::size_t size,
		int /*flags*/) {
	return packet_side_data_add(side_data, side_data_count, type, data, size);
}

extern "C" __declspec(dllexport) PacketSideData *__cdecl av_packet_side_data_new(
		PacketSideData **side_data,
		int *side_data_count,
		int type,
		std::size_t size,
		int /*flags*/) {
	if (size > SIZE_MAX - INPUT_BUFFER_PADDING_SIZE) {
		return nullptr;
	}
	AvutilApi &api = avutil_api();
	if (!api.is_valid()) {
		return nullptr;
	}
	auto *data = static_cast<std::uint8_t *>(api.malloc_fn(size + INPUT_BUFFER_PADDING_SIZE));
	if (data == nullptr) {
		return nullptr;
	}
	std::memset(data + size, 0, INPUT_BUFFER_PADDING_SIZE);
	PacketSideData *entry = packet_side_data_add(
		side_data,
		side_data_count,
		type,
		data,
		size
	);
	if (entry == nullptr) {
		api.free_fn(data);
	}
	return entry;
}

extern "C" __declspec(dllexport) const PacketSideData *__cdecl av_packet_side_data_get(
		const PacketSideData *side_data,
		int side_data_count,
		int type) {
	if (side_data == nullptr || side_data_count < 0) {
		return nullptr;
	}
	for (int index = 0; index < side_data_count; ++index) {
		if (side_data[index].type == type) {
			return &side_data[index];
		}
	}
	return nullptr;
}

// These private symbols belong to the FITS demuxer. PICO Cast uses FLV/RTMP,
// so returning failure keeps unrelated FITS input disabled without pulling a
// second full libavcodec build into the project.
extern "C" __declspec(dllexport) int __cdecl avpriv_fits_header_init(void *) {
	return -1;
}

extern "C" __declspec(dllexport) int __cdecl avpriv_fits_header_parse_line(void *) {
	return -1;
}
