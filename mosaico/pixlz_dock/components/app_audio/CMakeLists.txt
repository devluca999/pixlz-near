# Device: the microphone. The simulator builds app_audio_host.c from game.sim.json instead.
idf_component_register(
    SRCS "app_audio.c"
    INCLUDE_DIRS "include"
    PRIV_REQUIRES pixl_trip esp_driver_i2s esp_board_manager espressif__esp_codec_dev freertos log esp_driver_i2c
)
