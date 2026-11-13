# ESP-IDF component. On the host, use the Makefile (`make test`).
idf_component_register(
    SRCS "src/pt_sha256.c" "src/pt_crypto.c" "src/pt_pair.c" "src/pt_adpcm.c" "src/pt_frame.c" "src/pt_json.c" "src/pt_trip.c"
    INCLUDE_DIRS "include"
)
