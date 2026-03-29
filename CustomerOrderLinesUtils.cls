// ─── CustomerOrderLinesUtils ──────────────────────────────────────────────────
/**
 * Small, pure utility helpers — no DML, no SOQL, no side-effects.
 * Easy to unit-test without any test data setup.
 *
 *  prependDeletedTag() — adds "[DEL]" prefix unless already present.
 *  formatColName()     — builds a deterministic COL name from the OrderItem.
 */
// ─── CustomerOrderLinesUtils ──────────────────────────────────────────────────
public with sharing class CustomerOrderLinesUtils {
    public static String prependDeletedTag(String originalName) {
        if (String.isBlank(originalName))        return '[DEL]';
        if (originalName.startsWith('[DEL]'))     return originalName;
        return '[DEL] ' + originalName;
    }
    public static String formatColName(OrderItem o) {
        String key = (o.OrderItemNumber != null) ? o.OrderItemNumber : String.valueOf(o.Id);
        return 'COL-' + key;
    }
}
