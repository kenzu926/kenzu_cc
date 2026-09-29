package dev.kenzu.ccbridge;

import net.minecraftforge.event.ServerChatEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** Preserves Unicode plan commands before ComputerCraft's chat encoding can replace it. */
@Mod.EventBusSubscriber(modid = KenzuCcBridge.MOD_ID, bus = Mod.EventBusSubscriber.Bus.FORGE)
public final class PlanChatBridge {
    private static final int HISTORY_LIMIT = 64;
    private static final ArrayDeque<ChatEntry> HISTORY = new ArrayDeque<>();
    private static long sequence;

    private PlanChatBridge() {
    }

    @SubscribeEvent
    public static void onServerChat(ServerChatEvent event) {
        String rawText = event.getRawText();
        String lower = rawText.toLowerCase(Locale.ROOT);
        if (!lower.startsWith(".plan") && !lower.startsWith("$.plan")) return;

        synchronized (HISTORY) {
            sequence += 1;
            HISTORY.addLast(new ChatEntry(sequence, event.getUsername(), rawText));
            while (HISTORY.size() > HISTORY_LIMIT) HISTORY.removeFirst();
        }
    }

    static long latestId() {
        synchronized (HISTORY) {
            return sequence;
        }
    }

    static Map<String, Object> messagesAfter(long afterId) {
        List<Map<String, Object>> messages = new ArrayList<>();
        long latest;
        synchronized (HISTORY) {
            latest = sequence;
            for (ChatEntry entry : HISTORY) {
                if (entry.id() <= afterId) continue;
                Map<String, Object> value = new LinkedHashMap<>();
                value.put("id", entry.id());
                value.put("username", entry.username());
                value.put("codepoints", entry.text().codePoints().boxed().toList());
                messages.add(value);
            }
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("latestId", latest);
        result.put("messages", messages);
        return result;
    }

    private record ChatEntry(long id, String username, String text) {
    }
}
