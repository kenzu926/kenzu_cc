package dev.kenzu.ccbridge;

import com.mojang.logging.LogUtils;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.Difficulty;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.event.entity.player.PlayerEvent;
import net.minecraftforge.event.server.ServerStartedEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;
import org.slf4j.Logger;

import java.util.LinkedHashMap;
import java.util.Map;

/** Keeps empty servers peaceful and switches to hard whenever at least one player is online. */
@Mod.EventBusSubscriber(modid = KenzuCcBridge.MOD_ID, bus = Mod.EventBusSubscriber.Bus.FORGE)
public final class PlayerDifficultyPolicy {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static boolean updatePending = true;

    private PlayerDifficultyPolicy() {
    }

    @SubscribeEvent
    public static void onServerStarted(ServerStartedEvent event) {
        apply(event.getServer());
        updatePending = false;
    }

    @SubscribeEvent
    public static void onPlayerLogin(PlayerEvent.PlayerLoggedInEvent event) {
        updatePending = true;
    }

    @SubscribeEvent
    public static void onPlayerLogout(PlayerEvent.PlayerLoggedOutEvent event) {
        updatePending = true;
    }

    @SubscribeEvent
    public static void onServerTick(TickEvent.ServerTickEvent event) {
        if (event.phase != TickEvent.Phase.END || !updatePending) return;
        updatePending = false;
        apply(event.getServer());
    }

    static Map<String, Object> apply(MinecraftServer server) {
        int players = server.getPlayerList().getPlayerCount();
        Difficulty target = players > 0 ? Difficulty.HARD : Difficulty.PEACEFUL;
        Difficulty previous = server.getWorldData().getDifficulty();
        if (previous != target) {
            server.setDifficulty(target, true);
            LOGGER.info("Player difficulty policy: {} player(s), difficulty {} -> {}",
                players, previous.getKey(), target.getKey());
        }
        return result(server, players, target);
    }

    static Map<String, Object> status(MinecraftServer server) {
        int players = server.getPlayerList().getPlayerCount();
        Difficulty expected = players > 0 ? Difficulty.HARD : Difficulty.PEACEFUL;
        return result(server, players, expected);
    }

    private static Map<String, Object> result(MinecraftServer server, int players, Difficulty expected) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("enabled", true);
        result.put("players", players);
        result.put("difficulty", server.getWorldData().getDifficulty().getKey());
        result.put("expectedDifficulty", expected.getKey());
        result.put("matches", server.getWorldData().getDifficulty() == expected);
        return result;
    }
}
