"""Generates src/main/res/raw/watchface.xml for the BodyComp calorie face.

Run from anywhere:  python android/watchface/tools/gen_watchface.py

The face is a Watch Face Format (WFF) document. WFF has no loops, and the
ruler needs a different set of tick marks for each range, so the XML is
generated here instead of being written by hand. Change the numbers below
and re-run; do not edit watchface.xml directly.

Layout (450 x 450 design grid, scaled to the watch by the system):

    Mon 23            o o o o o  date, grey; battery, five dots (20% each),
                                 coloured red to green, going dark as it drains
    10:08                       time, watermelon
    | | | | | : | | | | |       ruler, one tick per 100 kcal, centre = even
         ####:                  bar: left/orange = burned ahead,
                                     right/yellow = eaten ahead
    o 1,480      o 1,790        eaten / burned today
      eaten        burned

Everything below the time lives inside ONE complication slot, fed by
CalorieComplicationService in the :wear module (see that file for the data
contract). The ruler adapts: it reaches to the next 500 kcal above the
current gap, and ticks tighten as it grows.
"""

from pathlib import Path

# ── Data contract with CalorieComplicationService ─────────────────────────
GAP_OFFSET = 5000  # complication value = (eaten - burned) + GAP_OFFSET
GAP_LIMIT = 5000   # the gap is clamped to +/- this
PROVIDER = (
    "com.scenicprints.bodycomp/"
    "com.scenicprints.bodycomp.wear.CalorieComplicationService"
)

# ── Look ──────────────────────────────────────────────────────────────────
FONT = "inter_regular"
WATERMELON = "#FFF5566E"
YELLOW = "#FFF2C500"  # eaten
ORANGE = "#FFF28C28"  # burned
WHITE = "#FFF1EFE8"
DATE_GREY = "#FFB4B2A9"

# ── Battery: five dots on the date line, one per 20% ──────────────────────
# Each dot has its own colour, low end to full end, so the last dot left lit
# is the watermelon one: the colour itself is the low-battery warning.
# A dot is lit while the battery is ABOVE its threshold (0, 20, 40, 60, 80).
BATTERY_COLOURS = ["#FFF5566E", "#FFF28C28", "#FFF2C500", "#FF9CCB3B", "#FF4CB86A"]
BATTERY_UNLIT = "#FF2C2C2A"
BATTERY_RIGHT = 356   # x of the last dot's centre: the right end of the ruler
BATTERY_Y = 104       # centre line of the date text
BATTERY_SPACING = 17.5
BATTERY_DOT = 11.5    # diameter
RULER_GREY = "#FF888780"

# ── Geometry of the calorie slot (coordinates local to the slot) ──────────
SLOT_X, SLOT_Y, SLOT_W, SLOT_H = 74, 236, 302, 160
CENTRE = 151       # x of the zero line
HALF = 131         # px from the zero line to either end of the ruler
TICK_BOTTOM = 32
TICK_SHORT_TOP = 24
TICK_TALL_TOP = 16  # every 500 kcal
BAR_Y, BAR_H = 40, 21

# Up to this range every 100 kcal gets a tick; beyond it only every 500,
# because 25+ ticks per side are too fine to read.
FINE_TICKS_UP_TO = 2000

VALUE = "[COMPLICATION.RANGED_VALUE_VALUE]"
GAP = f"({VALUE} - {GAP_OFFSET})"


def fmt(n: float) -> str:
    return f"{n:.1f}".rstrip("0").rstrip(".")


def tick(x: float, top: int) -> str:
    return (
        f'<Line startX="{fmt(x)}" startY="{top}" endX="{fmt(x)}" '
        f'endY="{TICK_BOTTOM}"><Stroke color="{RULER_GREY}" thickness="2"/></Line>'
    )


def ticks(rng: int) -> str:
    step = 100 if rng <= FINE_TICKS_UP_TO else 500
    out = []
    for kcal in range(step, rng + 1, step):
        dx = HALF * kcal / rng
        top = TICK_TALL_TOP if kcal % 500 == 0 else TICK_SHORT_TOP
        out.append(tick(CENTRE - dx, top))
        out.append(tick(CENTRE + dx, top))
    return "\n              ".join(out)


def bars(rng: int) -> str:
    over = f"clamp({GAP}, 0, {rng}) * {HALF} / {rng}"
    under = f"clamp(0 - {GAP}, 0, {rng}) * {HALF} / {rng}"
    return f"""<Rectangle x="{CENTRE}" y="{BAR_Y}" width="0" height="{BAR_H}">
                <Fill color="{YELLOW}"/>
                <Transform target="width" value="{over}"/>
              </Rectangle>
              <Rectangle x="{CENTRE}" y="{BAR_Y}" width="0" height="{BAR_H}">
                <Fill color="{ORANGE}"/>
                <Transform target="x" value="{CENTRE} - {under}"/>
                <Transform target="width" value="{under}"/>
              </Rectangle>"""


def ruler(rng: int) -> str:
    return f"""<PartDraw x="0" y="0" width="{SLOT_W}" height="{SLOT_H}">
              {ticks(rng)}
            </PartDraw>
            <PartDraw x="0" y="0" width="{SLOT_W}" height="{SLOT_H}">
              {bars(rng)}
            </PartDraw>"""


def number(x: int, source: str, label: str, colour: str) -> str:
    return f"""<PartDraw x="0" y="0" width="{SLOT_W}" height="{SLOT_H}">
          <Ellipse x="{x}" y="91" width="16" height="16"><Fill color="{colour}"/></Ellipse>
        </PartDraw>
        <PartText x="{x + 29}" y="78" width="112" height="42">
          <Text align="START">
            <Font family="{FONT}" size="33" color="{WHITE}">
              <Template><![CDATA[%s]]><Parameter expression="[COMPLICATION.{source}]"/></Template>
            </Font>
          </Text>
        </PartText>
        <PartText x="{x + 29}" y="118" width="112" height="30">
          <Text align="START">
            <Font family="{FONT}" size="22" color="{RULER_GREY}">{label}</Font>
          </Text>
        </PartText>"""


def battery() -> str:
    """Five unlit dots, then each lit dot on top while the battery is above its step."""
    def dot(i: int, colour: str) -> str:
        x = BATTERY_RIGHT - (4 - i) * BATTERY_SPACING - BATTERY_DOT / 2
        y = BATTERY_Y - BATTERY_DOT / 2
        return (
            f'<Ellipse x="{fmt(x)}" y="{fmt(y)}" width="{BATTERY_DOT}" '
            f'height="{BATTERY_DOT}"><Fill color="{colour}"/></Ellipse>'
        )

    unlit = "\n        ".join(dot(i, BATTERY_UNLIT) for i in range(5))
    lit = "\n      ".join(
        f"""<Condition>
        <Expressions>
          <Expression name="above{i * 20}"><![CDATA[[BATTERY_PERCENT] > {i * 20}]]></Expression>
        </Expressions>
        <Compare expression="above{i * 20}">
          <PartDraw x="0" y="0" width="450" height="450">
            {dot(i, colour)}
          </PartDraw>
        </Compare>
      </Condition>"""
        for i, colour in enumerate(BATTERY_COLOURS)
    )
    return f"""<Group x="0" y="0" width="450" height="450" name="battery">
      <Variant mode="AMBIENT" target="alpha" value="170"/>
      <PartDraw x="0" y="0" width="450" height="450">
        {unlit}
      </PartDraw>
      {lit}
    </Group>"""


def build() -> str:
    ranges = list(range(500, GAP_LIMIT, 500))  # the last range is the Default
    expressions = "\n            ".join(
        f'<Expression name="r{r}"><![CDATA[abs({GAP}) <= {r}]]></Expression>'
        for r in ranges
    )
    compares = "\n          ".join(
        f'<Compare expression="r{r}">\n            {ruler(r)}\n          </Compare>'
        for r in ranges
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- GENERATED by tools/gen_watchface.py. Do not edit by hand. -->
<WatchFace width="450" height="450">
  <Metadata key="CLOCK_TYPE" value="DIGITAL"/>
  <Metadata key="PREVIEW_TIME" value="10:08:32"/>
  <Scene backgroundColor="#FF000000">

    <Group x="0" y="0" width="450" height="450" name="date">
      <Variant mode="AMBIENT" target="alpha" value="170"/>
      <PartText x="94" y="82" width="262" height="40">
        <Text align="START">
          <Font family="{FONT}" size="27" color="{DATE_GREY}">
            <Template><![CDATA[%s %s]]><Parameter expression="[DAY_OF_WEEK_S]"/><Parameter expression="[DAY]"/></Template>
          </Font>
        </Text>
      </PartText>
    </Group>

    {battery()}

    <DigitalClock x="89" y="118" width="320" height="120">
      <Variant mode="AMBIENT" target="alpha" value="200"/>
      <TimeText format="h:mm" hourFormat="SYNC_TO_DEVICE" align="START" x="0" y="0" width="320" height="120">
        <Font family="{FONT}" size="106" color="{WATERMELON}"/>
      </TimeText>
    </DigitalClock>

    <ComplicationSlot x="{SLOT_X}" y="{SLOT_Y}" width="{SLOT_W}" height="{SLOT_H}" slotId="0" displayName="calories_slot" supportedTypes="RANGED_VALUE EMPTY">
      <DefaultProviderPolicy defaultSystemProvider="EMPTY" defaultSystemProviderType="EMPTY" primaryProvider="{PROVIDER}" primaryProviderType="RANGED_VALUE"/>
      <BoundingBox x="0" y="0" width="{SLOT_W}" height="{SLOT_H}"/>
      <Complication type="RANGED_VALUE">
        <PartDraw x="0" y="0" width="{SLOT_W}" height="{SLOT_H}">
          <Line startX="{CENTRE}" startY="9" endX="{CENTRE}" endY="71"><Stroke color="{RULER_GREY}" thickness="2"/></Line>
        </PartDraw>
        <Condition>
          <Expressions>
            {expressions}
          </Expressions>
          {compares}
          <Default>
            {ruler(GAP_LIMIT)}
          </Default>
        </Condition>
        {number(20, "TEXT", "eaten", YELLOW)}
        {number(163, "TITLE", "burned", ORANGE)}
      </Complication>
      <Variant mode="AMBIENT" target="alpha" value="170"/>
    </ComplicationSlot>

  </Scene>
</WatchFace>
"""


if __name__ == "__main__":
    out = Path(__file__).resolve().parents[1] / "src/main/res/raw/watchface.xml"
    out.write_text(build(), encoding="utf-8", newline="\n")
    print(f"wrote {out}")
