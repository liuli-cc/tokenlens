import { Audio } from "@remotion/media";
import { loadFont } from "@remotion/fonts";
import {
  AbsoluteFill,
  CanvasImage,
  Composition,
  Easing,
  Interactive,
  interpolate,
  staticFile,
  useCurrentFrame,
} from "remotion";

loadFont({
  family: "Noto Film",
  url: staticFile("fonts/NotoSansSC-VF.ttf"),
  weight: "100 900",
});
const ease = {
  extrapolateLeft: "clamp",
  extrapolateRight: "clamp",
  easing: Easing.bezier(0.22, 1, 0.36, 1),
} as const;

const BrandChip = ({
  label,
  image,
  color,
  x,
  y,
  delay,
}: {
  label: string;
  image: string;
  color: string;
  x: number;
  y: number;
  delay: number;
}) => {
  const frame = useCurrentFrame();
  const entrance = interpolate(frame, [240 + delay, 300 + delay], [0, 1], ease);
  const gather = interpolate(
    frame,
    [450 + delay / 2, 540 + delay / 2],
    [0, 1],
    ease,
  );
  const disappear = interpolate(frame, [564, 606], [1, 0], ease);
  return (
    <div
      style={{
        position: "absolute",
        left: 960,
        top: 668,
        translate: `${x * entrance * (1 - gather)}px ${y * entrance * (1 - gather) - 74 * gather}px`,
        scale: interpolate(
          frame,
          [240 + delay, 286 + delay, 478 + delay / 2, 568],
          [0.12, 1, 1, 0.5],
          ease,
        ),
        opacity:
          entrance *
          disappear *
          interpolate(gather, [0, 0.72, 1], [1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        width: 180,
        marginLeft: -90,
        textAlign: "center",
      }}
    >
      <div
        style={{
          width: 148,
          height: 148,
          margin: "0 auto",
          borderRadius: 40,
          background: `${color}15`,
          boxShadow: `0 16px 36px ${color}18`,
          rotate: `${(1 - entrance) * 18}deg`,
        }}
      >
        <CanvasImage
          src={staticFile(image)}
          style={{ width: 160, height: 160, marginLeft: -6, marginTop: -6 }}
        />
      </div>
      <div
        style={{
          fontSize: 29,
          fontWeight: 650,
          marginTop: 14,
          opacity: interpolate(
            frame,
            [450 + delay / 2, 478 + delay / 2],
            [1, 0],
            ease,
          ),
          color: "#222522",
          whiteSpace: "nowrap",
        }}
      >
        {label}
      </div>
    </div>
  );
};

const Assistants = () => (
  <>
    <BrandChip
      label="GPT / Codex"
      image="brand/gpt-codex.png"
      color="#BF88FC"
      x={-635}
      y={-70}
      delay={0}
    />
    <BrandChip
      label="DeepSeek Harness"
      image="brand/deepseek-harness.png"
      color="#7A82F2"
      x={-326}
      y={80}
      delay={12}
    />
    <BrandChip
      label="WorkBuddy"
      image="brand/workbuddy.png"
      color="#3BBDA2"
      x={0}
      y={80}
      delay={24}
    />
    <BrandChip
      label="Claude"
      image="brand/claude.png"
      color="#D58A68"
      x={326}
      y={80}
      delay={36}
    />
    <BrandChip
      label="CodeBuddy"
      image="brand/codebuddy.png"
      color="#927EF1"
      x={635}
      y={-70}
      delay={48}
    />
  </>
);

const Metric = ({
  label,
  value,
  unit,
  x,
  progress,
  color,
}: {
  label: string;
  value: string;
  unit: string;
  x: number;
  progress: number;
  color: string;
}) => (
  <div style={{ position: "absolute", left: x, top: 116, width: 290 }}>
    <div style={{ fontSize: 26, color: "#8A938E", fontWeight: 550 }}>
      {label}
    </div>
    <div
      style={{
        fontSize: 75,
        letterSpacing: "-4px",
        fontWeight: 650,
        marginTop: 7,
        lineHeight: 1.2,
      }}
    >
      {value}
      <span
        style={{
          fontSize: 36,
          letterSpacing: "-1px",
          marginLeft: 5,
          color: "#98A59D",
        }}
      >
        {unit}
      </span>
    </div>
    <div
      style={{
        height: 5,
        width: 256,
        background: "#283029",
        borderRadius: 5,
        marginTop: 19,
        overflow: "hidden",
      }}
    >
      <div
        style={{
          height: "100%",
          width: `${progress * 100}%`,
          background: color,
          borderRadius: 5,
        }}
      />
    </div>
  </div>
);

// A single persistent island changes shape throughout the entire film.
const Island = () => {
  const frame = useCurrentFrame();
  const metricVisibility = interpolate(
    frame,
    [588, 648, 898, 960],
    [0, 1, 1, 0],
    ease,
  );
  const completionVisibility = interpolate(
    frame,
    [978, 1012, 1280, 1320],
    [0, 1, 1, 0],
    ease,
  );
  const n = interpolate(frame, [618, 810], [0, 1], ease);
  const glow = interpolate(
    frame,
    [930, 968, 991, 1011, 1048, 1160, 1300, 1360],
    [0, 0.2, 1, 0.66, 0.83, 0.4, 0.3, 0],
    ease,
  );
  return (
    <Interactive.Div
      name="Persistent morphing island"
      style={{
        position: "absolute",
        left: interpolate(
          frame,
          [0, 1288, 1392, 1524, 1644],
          [960, 960, 525, 525, 960],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          },
        ),
        top: interpolate(
          frame,
          [0, 46, 234, 576, 660, 930, 1038, 1288, 1392, 1524, 1630],
          [616, 680, 668, 668, 645, 645, 646, 646, 510, 510, 525],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          },
        ),
        width: interpolate(
          frame,
          [
            0, 40, 96, 230, 330, 564, 650, 930, 977, 994, 1008, 1035, 1300,
            1392, 1524, 1620,
          ],
          [
            112, 112, 614, 614, 446, 446, 1140, 1140, 1140, 1150, 1136, 1140,
            1140, 418, 418, 124,
          ],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          },
        ),
        height: interpolate(
          frame,
          [
            0, 40, 96, 230, 330, 564, 650, 930, 977, 994, 1008, 1035, 1300,
            1392, 1524, 1620,
          ],
          [
            112, 112, 180, 180, 138, 138, 316, 316, 270, 262, 273, 270, 270, 86,
            86, 124,
          ],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          },
        ),
        translate: "-50% -50%",
        scale: interpolate(frame, [0, 12, 38, 66], [0.02, 0.25, 1.07, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.bezier(0.22, 1, 0.36, 1),
          output: "perceptual-scale",
        }),
        borderRadius: interpolate(
          frame,
          [0, 96, 564, 650, 930, 1038, 1300, 1392, 1524, 1620],
          [80, 70, 70, 58, 58, 63, 63, 40, 40, 36],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          },
        ),
        color: "#F7F8F2",
        background:
          "linear-gradient(145deg, #20241F 0%, #101410 58%, #060906 100%)",
        boxShadow: `0 1px 0 #ffffff40 inset, 0 22px 44px #17251620, 0 0 ${10 + glow * 26}px #C294FF${Math.round(
          glow * 156,
        )
          .toString(16)
          .padStart(2, "0")}, 0 0 ${32 + glow * 42}px #A770FF${Math.round(
          glow * 80,
        )
          .toString(16)
          .padStart(2, "0")}`,
        border: `2px solid rgba(${frame >= 930 && frame <= 1320 ? "203,159,255" : "135,158,120"},${0.13 + glow * 0.72})`,
        overflow: "hidden",
      }}
    >
      <Interactive.Div
        name="Opening island signature"
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          gap: 24,
          opacity: interpolate(frame, [55, 110, 568, 612], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      >
        <div
          style={{
            height: 17,
            width: 17,
            borderRadius: 20,
            background: "#CEF487",
            boxShadow: "0 0 21px #CEF48766",
          }}
        />
        <div style={{ fontSize: 43, fontWeight: 600, letterSpacing: "-1px" }}>
          TokenLens
        </div>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 6,
            marginLeft: 24,
          }}
        >
          {[0, 1, 2, 3].map((i) => (
            <div
              key={i}
              style={{
                width: 5,
                height: 14 + Math.sin((frame / 30) * Math.PI * 2 + i) * 6,
                borderRadius: 4,
                background: "#B6CBB2",
              }}
            />
          ))}
        </div>
      </Interactive.Div>
      <div
        style={{ position: "absolute", inset: 0, opacity: metricVisibility }}
      >
        <CanvasImage
          src={staticFile("brand/gpt-codex.png")}
          style={{
            position: "absolute",
            left: 48,
            top: 20,
            width: 65,
            height: 65,
          }}
        />
        <div
          style={{
            position: "absolute",
            left: 126,
            top: 37,
            fontSize: 30,
            fontWeight: 650,
          }}
        >
          GPT / Codex
        </div>
        <div
          style={{
            position: "absolute",
            right: 52,
            top: 41,
            color: "#A9C897",
            fontSize: 22,
            fontWeight: 550,
          }}
        >
          有来源的用量
        </div>
        <Metric
          label="输入 TOKEN"
          value={(42.8 * n).toFixed(1)}
          unit="K"
          x={66}
          progress={n * 0.68}
          color="#CEF487"
        />
        <Metric
          label="输出 TOKEN"
          value={(8.2 * n).toFixed(1)}
          unit="K"
          x={414}
          progress={n * 0.36}
          color="#AFA9F4"
        />
        <Metric
          label="上下文估算"
          value={`≈${Math.round(63 * n)}`}
          unit="%"
          x={770}
          progress={n * 0.63}
          color="#76D6B3"
        />
      </div>
      <div
        style={{
          position: "absolute",
          inset: 0,
          opacity: completionVisibility,
        }}
      >
        <CanvasImage
          src={staticFile("brand/gpt-codex.png")}
          style={{
            position: "absolute",
            left: 53,
            top: 65,
            width: 126,
            height: 126,
          }}
        />
        <div
          style={{
            position: "absolute",
            left: 214,
            top: 42,
            fontSize: 27,
            color: "#CFACFF",
            fontWeight: 650,
          }}
        >
          任务已完成 · GPT / Codex
        </div>
        <div
          style={{
            position: "absolute",
            left: 214,
            top: 90,
            fontSize: 50,
            letterSpacing: "-2px",
            fontWeight: 650,
          }}
        >
          灵感落地，轻轻提醒。
        </div>
        <div
          style={{
            position: "absolute",
            left: 214,
            top: 177,
            fontSize: 25,
            color: "#91A18F",
          }}
        >
          点击回到来源 · 继续你的专注
        </div>
        <div
          style={{
            position: "absolute",
            right: 51,
            top: 85,
            fontSize: 65,
            color: "#CFACFF",
          }}
        >
          ↗
        </div>
        <div
          style={{
            position: "absolute",
            left: 138,
            top: 149,
            width: 43,
            height: 43,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: "#C794FF",
            color: "#171217",
            border: "5px solid #101410",
            borderRadius: 50,
            fontSize: 25,
            fontWeight: 900,
          }}
        >
          ✓
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          justifyContent: "center",
          alignItems: "center",
          gap: 12,
          opacity: interpolate(
            frame,
            [1330, 1392, 1508, 1530],
            [0, 1, 1, 0],
            ease,
          ),
          fontSize: 22,
          fontWeight: 650,
        }}
      >
        <div
          style={{
            height: 8,
            width: 8,
            background: "#C793FF",
            borderRadius: 8,
          }}
        />{" "}
        GPT / Codex{" "}
        <span style={{ color: "#CBF1A3", marginLeft: 12 }}>42.8K</span>
      </div>
      <Interactive.Div
        name="Closing brand bars"
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          justifyContent: "center",
          alignItems: "center",
          gap: 9,
          opacity: interpolate(frame, [1570, 1650], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          }),
        }}
      >
        <div
          style={{
            width: 15,
            height: 32,
            borderRadius: 5,
            background: "#C399FF",
          }}
        />
        <div
          style={{
            width: 15,
            height: 57,
            borderRadius: 5,
            background: "#AE78F0",
          }}
        />
        <div
          style={{
            width: 15,
            height: 44,
            borderRadius: 5,
            background: "#8C58D7",
          }}
        />
      </Interactive.Div>
    </Interactive.Div>
  );
};

const Device = ({ windows }: { windows: boolean }) => {
  const frame = useCurrentFrame();
  return (
    <div
      style={{
        position: "absolute",
        left: windows ? 1020 : 150,
        top: 455,
        width: 750,
        height: 390,
        translate: `0px ${interpolate(frame, [1280 + (windows ? 14 : 0), 1380, 1524, 1600], [160, 0, 0, 100], ease)}px`,
        scale: interpolate(
          frame,
          [1280, 1380, 1524, 1600],
          [0.83, 1, 1, 0.87],
          ease,
        ),
        opacity: interpolate(
          frame,
          [1290, 1370, 1524, 1590],
          [0, 1, 1, 0],
          ease,
        ),
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: 0,
          border: "2px solid #737D70",
          borderRadius: windows ? 25 : 29,
          padding: 14,
          background: "#33382E",
          boxShadow: "0 25px 60px #14230F20",
        }}
      >
        <div
          style={{
            position: "absolute",
            inset: 12,
            borderRadius: 18,
            background: windows
              ? "linear-gradient(125deg,#CFDDD0,#E4EACB)"
              : "linear-gradient(135deg,#D4DAC7,#E9E8CE)",
            overflow: "hidden",
          }}
        >
          <div
            style={{
              position: "absolute",
              width: 760,
              height: 600,
              border: "1px solid #8F9E6B55",
              borderRadius: "50%",
              left: -150,
              top: 130,
              rotate: "-22deg",
            }}
          />
          <div
            style={{
              position: "absolute",
              width: 760,
              height: 600,
              border: "1px solid #8F9E6B55",
              borderRadius: "50%",
              left: -95,
              top: 152,
              rotate: "-22deg",
            }}
          />
          <div
            style={{
              position: "absolute",
              width: 760,
              height: 600,
              border: "1px solid #8F9E6B55",
              borderRadius: "50%",
              left: -40,
              top: 174,
              rotate: "-22deg",
            }}
          />
          {windows ? (
            <div
              style={{
                position: "absolute",
                bottom: 0,
                width: "100%",
                height: 27,
                display: "flex",
                justifyContent: "center",
                gap: 12,
                alignItems: "center",
                background: "#EBEDDBCC",
              }}
            >
              <svg width="14" height="14" viewBox="0 0 20 20">
                <path
                  d="M1 1h8v8H1zm10 0h8v8h-8zM1 11h8v8H1zm10 0h8v8h-8z"
                  fill="#728957"
                />
              </svg>
              <span
                style={{
                  height: 13,
                  width: 30,
                  borderRadius: 3,
                  background: "#97A98F",
                }}
              />
              <span
                style={{
                  height: 13,
                  width: 13,
                  borderRadius: 3,
                  background: "#B7C692",
                }}
              />
            </div>
          ) : (
            <>
              <div
                style={{
                  position: "absolute",
                  top: 0,
                  left: 270,
                  width: 185,
                  height: 29,
                  background: "#171D15",
                  borderRadius: "0 0 14px 14px",
                }}
              />
              <div
                style={{
                  position: "absolute",
                  bottom: 9,
                  left: 265,
                  width: 198,
                  height: 36,
                  background: "#EFF0DE9F",
                  border: "1px solid #FFFFFF80",
                  borderRadius: 12,
                  display: "flex",
                  gap: 9,
                  alignItems: "center",
                  justifyContent: "center",
                }}
              >
                <CanvasImage
                  src={staticFile("brand/gpt-codex.png")}
                  style={{ width: 32, height: 32 }}
                />
                <CanvasImage
                  src={staticFile("brand/claude.png")}
                  style={{ width: 32, height: 32 }}
                />
                <CanvasImage
                  src={staticFile("brand/workbuddy.png")}
                  style={{ width: 32, height: 32 }}
                />
                <CanvasImage
                  src={staticFile("brand/tokenlens.png")}
                  style={{ width: 24, height: 24, borderRadius: 6 }}
                />
              </div>
            </>
          )}
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          bottom: -12,
          left: -26,
          width: 802,
          height: 15,
          background: "linear-gradient(#7F8772,#B8BDAA)",
          borderRadius: "0 0 22px 22px",
        }}
      />
      <div
        style={{
          position: "absolute",
          top: 448,
          width: "100%",
          textAlign: "center",
          fontSize: 35,
          fontWeight: 600,
          color: "#4E5B45",
        }}
      >
        {windows ? "Windows" : "macOS"}
      </div>
    </div>
  );
};

const Headings = () => {
  const frame = useCurrentFrame();
  return (
    <>
      <Interactive.Div
        name="Opening headline"
        style={{
          position: "absolute",
          left: 170,
          top: 150,
          width: 1580,
          textAlign: "center",
          fontSize: 144,
          letterSpacing: "-9px",
          fontWeight: 750,
          lineHeight: 1.17,
          opacity: interpolate(frame, [18, 60, 202, 242], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(
            frame,
            [18, 60, 202, 242],
            ["0px 65px", "0px 0px", "0px 0px", "0px -50px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.22, 1, 0.36, 1),
            },
          ),
        }}
      >
        AI 工作，
        <br />
        自有节奏。
      </Interactive.Div>
      <Interactive.Div
        name="Assistants headline"
        style={{
          position: "absolute",
          left: 130,
          top: 190,
          width: 1660,
          textAlign: "center",
          fontSize: 123,
          letterSpacing: "-7px",
          fontWeight: 750,
          opacity: interpolate(frame, [244, 282, 536, 582], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(
            frame,
            [244, 282, 536, 582],
            ["0px 60px", "0px 0px", "0px 0px", "0px -40px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.22, 1, 0.36, 1),
            },
          ),
        }}
      >
        五位助手。<span style={{ color: "#638B3D" }}>一个焦点。</span>
      </Interactive.Div>
      <Interactive.Div
        name="Metrics headline"
        style={{
          position: "absolute",
          left: 150,
          top: 170,
          width: 1620,
          textAlign: "center",
          fontSize: 125,
          letterSpacing: "-7px",
          fontWeight: 750,
          opacity: interpolate(frame, [588, 628, 899, 940], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(
            frame,
            [588, 628, 899, 940],
            ["0px 55px", "0px 0px", "0px 0px", "0px -45px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.22, 1, 0.36, 1),
            },
          ),
        }}
      >
        用量。上下文。
        <br />
        <span style={{ color: "#638B3D" }}>看得见。</span>
      </Interactive.Div>
      <Interactive.Div
        name="Completion headline"
        style={{
          position: "absolute",
          left: 170,
          top: 215,
          width: 1580,
          textAlign: "center",
          fontSize: 132,
          color: "#F6F5EA",
          letterSpacing: "-8px",
          fontWeight: 700,
          opacity: interpolate(frame, [954, 1000, 1256, 1304], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(
            frame,
            [954, 1000, 1256, 1304],
            ["0px 55px", "0px 0px", "0px 0px", "0px -35px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.22, 1, 0.36, 1),
            },
          ),
        }}
      >
        完成，就有<span style={{ color: "#D0AEFF" }}>回响。</span>
      </Interactive.Div>
      <Interactive.Div
        name="Cross-platform headline"
        style={{
          position: "absolute",
          left: 130,
          top: 159,
          width: 1660,
          textAlign: "center",
          fontSize: 112,
          letterSpacing: "-7px",
          fontWeight: 750,
          lineHeight: 1.15,
          opacity: interpolate(frame, [1290, 1348, 1510, 1566], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(
            frame,
            [1290, 1348, 1510, 1566],
            ["0px 48px", "0px 0px", "0px 0px", "0px -38px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.22, 1, 0.36, 1),
            },
          ),
        }}
      >
        Mac 和 Windows。
        <br />
        <span style={{ color: "#638B3D" }}>都在节奏里。</span>
      </Interactive.Div>
      <Interactive.Div
        name="Closing wordmark"
        style={{
          position: "absolute",
          left: 120,
          top: 199,
          width: 1680,
          textAlign: "center",
          fontSize: 203,
          letterSpacing: "-13px",
          fontWeight: 750,
          opacity: interpolate(frame, [1552, 1614], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(frame, [1552, 1614], ["0px 60px", "0px 0px"], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          }),
        }}
      >
        TokenLens<span style={{ color: "#789B49" }}>.</span>
      </Interactive.Div>
      <Interactive.Div
        name="Closing promise"
        style={{
          position: "absolute",
          left: 160,
          top: 650,
          width: 1600,
          textAlign: "center",
          fontSize: 64,
          letterSpacing: "-2px",
          fontWeight: 600,
          opacity: interpolate(frame, [1630, 1680], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(frame, [1630, 1680], ["0px 28px", "0px 0px"], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.22, 1, 0.36, 1),
          }),
        }}
      >
        让 AI 工作，更有感觉。
      </Interactive.Div>
      <Interactive.Div
        name="Closing download link"
        style={{
          position: "absolute",
          left: 160,
          top: 785,
          width: 1600,
          textAlign: "center",
          fontSize: 30,
          letterSpacing: "0.2px",
          color: "#59674F",
          fontWeight: 500,
          opacity: interpolate(frame, [1670, 1730], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      >
        macOS + Windows / github.com/liuli-cc/tokenlens
      </Interactive.Div>
    </>
  );
};

export const TokenLensFilm = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill
      name="TokenLens — Work in flow"
      style={{
        background: "#F5F4EA",
        overflow: "hidden",
        color: "#20241F",
        fontFamily: "Noto Film, sans-serif",
      }}
    >
      <Audio
        name="Original 120 BPM groove"
        src={staticFile("audio/tokenlens-groove.wav")}
        volume={0.95}
      />
      <Interactive.Div
        name="Continuous orbital line"
        style={{
          position: "absolute",
          left: -435,
          top: 455,
          width: 2760,
          height: 1160,
          border: "1px solid #A1B78640",
          borderRadius: "50%",
          rotate: interpolate(frame, [0, 1920], ["-18deg", "12deg"], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          scale: interpolate(
            frame,
            [0, 240, 660, 930, 1320, 1620, 1919],
            [0.7, 1, 0.9, 1.05, 1, 0.72, 0.86],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.22, 1, 0.36, 1),
            },
          ),
        }}
      />
      <Interactive.Div
        name="Dark ripple from island"
        style={{
          position: "absolute",
          left: 960,
          top: 647,
          width: 2640,
          height: 2640,
          marginLeft: -1320,
          marginTop: -1320,
          background: "#171B18",
          borderRadius: "50%",
          scale: interpolate(frame, [904, 994, 1240, 1356], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.65, 0, 0.35, 1),
          }),
        }}
      />
      <Interactive.Div
        name="Brand signature"
        style={{
          position: "absolute",
          left: 112,
          top: 71,
          display: "flex",
          gap: 12,
          alignItems: "center",
          fontSize: 23,
          letterSpacing: "0.4px",
          fontWeight: 650,
          opacity: interpolate(
            frame,
            [0, 32, 899, 969, 1280, 1370, 1570, 1630],
            [0, 1, 1, 0, 0, 1, 1, 0],
            { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
          ),
        }}
      >
        <CanvasImage
          src={staticFile("brand/tokenlens.png")}
          style={{ width: 33, height: 33, borderRadius: 9 }}
        />
        TokenLens
      </Interactive.Div>
      <div
        style={{
          position: "absolute",
          right: 116,
          top: 78,
          fontSize: 15,
          letterSpacing: "3px",
          color: frame > 950 && frame < 1320 ? "#9CA89D" : "#859274",
        }}
      >
        WORK IN FLOW
      </div>
      <Device windows={false} />
      <Device windows />
      <Headings />
      <Assistants />
      <Island />
      <Interactive.Div
        name="Windows island continuation"
        style={{
          position: "absolute",
          left: 1392,
          top: 510,
          width: 418,
          height: 86,
          borderRadius: 40,
          background: "#101410",
          color: "#F8F6ED",
          border: "1px solid #798D64",
          boxShadow: "0 12px 26px #17251625",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          gap: 12,
          fontSize: 22,
          fontWeight: 650,
          opacity: interpolate(frame, [1320, 1392, 1524, 1584], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          translate: interpolate(
            frame,
            [1320, 1392, 1524, 1584],
            ["-50% 60%", "-50% -50%", "-50% -50%", "-50% -100%"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.22, 1, 0.36, 1),
            },
          ),
        }}
      >
        <div
          style={{
            height: 8,
            width: 8,
            background: "#C793FF",
            borderRadius: 8,
          }}
        />
        GPT / Codex
        <span style={{ color: "#CBF1A3", marginLeft: 12 }}>42.8K</span>
      </Interactive.Div>
      <Interactive.Div
        name="Metric demonstration note"
        style={{
          position: "absolute",
          left: 160,
          top: 905,
          width: 1600,
          textAlign: "center",
          fontSize: 24,
          color: "#7C8971",
          opacity: interpolate(frame, [660, 708, 884, 930], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      >
        界面与数据为演示 · 实际显示以本机可读取记录为准
      </Interactive.Div>
      <Interactive.Div
        name="Completion sources"
        style={{
          position: "absolute",
          left: 160,
          top: 872,
          width: 1600,
          textAlign: "center",
          fontSize: 28,
          color: "#889788",
          opacity: interpolate(frame, [1040, 1100, 1240, 1300], [0, 1, 1, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      >
        完成提醒：GPT / Codex · DeepSeek Harness
      </Interactive.Div>
      <div
        style={{
          position: "absolute",
          bottom: 70,
          left: 114,
          width: 1688,
          height: 2,
          background: frame > 950 && frame < 1320 ? "#3A4439" : "#DDE2D1",
        }}
      >
        <div
          style={{
            height: 2,
            width: `${(frame / 1919) * 100}%`,
            background: frame > 950 && frame < 1320 ? "#CEABFF" : "#8BA858",
          }}
        />
      </div>
    </AbsoluteFill>
  );
};

export const MyComposition = () => (
  <Composition
    id="TokenLens-Work-In-Flow"
    component={TokenLensFilm}
    durationInFrames={1920}
    fps={60}
    width={1920}
    height={1080}
    defaultProps={{}}
  />
);
