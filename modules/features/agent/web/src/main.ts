import { mount } from "svelte";
import "./app.css";
import App from "./App.svelte";
import { followDesktopTheme } from "./lib/theme";

followDesktopTheme();
mount(App, { target: document.getElementById("app")! });
