# The simulator builds app_dock.c + app_dock_platform_host.c from game.sim.json instead.
idf_component_register(
    SRCS "app_dock.c" "app_dock_platform_esp.c"
    INCLUDE_DIRS "include"
    PRIV_INCLUDE_DIRS "private"
    PRIV_REQUIRES pixl_trip esp_wifi esp_netif esp_event nvs_flash lwip mdns esp_driver_i2c esp_board_manager esp_iris esp_mosaico_app_recovery app_ble
)
