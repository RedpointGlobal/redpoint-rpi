![redpoint_logo](../chart/images/redpoint.png)
# Custom Realtime Plugins

[< Back to Home](../README.md)

Developers can extend the RPI Realtime API by building custom plugins. Plugins run inside the Realtime API container and hook into different points of the request lifecycle (decisions, events, forms, visitor profiles, geolocation).

This guide covers plugin types, how to build them, and how to configure them in the Helm chart.

---

## Getting Started

Plugins are .NET 9 class libraries that reference the `RedPoint.Web.Shared` NuGet package.

**NuGet feed:** `https://nuget.redpointcdp.com/packages/index.json`

**Example project:** [RPI-Realtime-Plugin-Example](https://github.com/RedPointGlobal/RPI-Realtime-Plugin-Example)

Each plugin needs two classes (except Geolocation plugins which only need the plugin class):
- **Factory class** - initializes new plugin instances and sets configuration
- **Plugin class** - contains the execution logic

Once compiled, the DLL is uploaded to shared storage and mounted into the Realtime API container via a PVC.

---

## Plugin Types

<details>
<summary><strong>Decision Plugins</strong></summary>

These hook into the decision flow at three points: before the decision, after the decision, and after all Smart Asset decisions complete.

#### Pre-decision

Runs before the decision is made. Use it to modify the request or add data.

| | |
|:---|:---|
| **Endpoint** | [/api/v2/smart-assets/results](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/smart-assets/results) |
| **Factory Base Class** | `RedPoint.Resonance.Web.Shared.Plugins.FilterableRealtimePluginFactoryBase` |
| **Plugin Interface** | `RedPoint.Resonance.Web.Shared.Plugins.IPredecisionPlugin` |
| **Inputs** | Decision Request Details, Visitor Profile |
| **Outputs** | Visitor Profile |
| **Configuration Type** | `Predecision` |

#### Post-decision

Runs after a decision is made. Use it to modify the result before it's returned.

| | |
|:---|:---|
| **Endpoint** | [/api/v2/smart-assets/results](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/smart-assets/results) |
| **Factory Base Class** | `RedPoint.Resonance.Web.Shared.Plugins.IRealtimePluginFactory` |
| **Plugin Interface** | `RedPoint.Resonance.Web.Shared.Plugins.IDecisionContentPlugin` |
| **Inputs** | Decision Result, Visitor Profile |
| **Outputs** | Decision Result |
| **Configuration Type** | N/A |

#### Smart Asset

Runs after all decisions for a Smart Asset request complete. Use it to process the full response.

| | |
|:---|:---|
| **Endpoint** | [/api/v2/smart-assets/results](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/smart-assets/results) |
| **Factory Base Class** | `RedPoint.Resonance.Web.Shared.Plugins.FilterableRealtimePluginFactoryBase` |
| **Plugin Interface** | `RedPoint.Resonance.Web.Shared.Plugins.ISmartAssetResultsPlugin` |
| **Inputs** | Request Details, Collection of Decision Results, Visitor Profile |
| **Outputs** | Collection of Decision Results |
| **Configuration Type** | `SmartAssetResults` |

</details>

<details>
<summary><strong>Event Plugins</strong></summary>

Process or modify any realtime event (e.g. Page Visit).

| | |
|:---|:---|
| **Endpoint** | [/api/v2/events](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/events) |
| **Factory Base Class** | `RedPoint.Resonance.Web.Shared.Plugins.FilterableRealtimePluginFactoryBase` |
| **Plugin Interface** | `RedPoint.Resonance.Web.Shared.Plugins.IEventPlugin` |
| **Inputs** | Realtime Event |
| **Outputs** | Realtime Event |
| **Configuration Type** | `Event` |

</details>

<details>
<summary><strong>Form Plugins</strong></summary>

Process or modify web form submission data before RPI ingests it.

| | |
|:---|:---|
| **Endpoint** | [/api/v2/form-data](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/form-data) |
| **Factory Base Class** | `RedPoint.Resonance.Web.Shared.Plugins.IFormProcessingPluginFactory` |
| **Plugin Interface** | `RedPoint.Resonance.Web.Shared.Plugins.IFormProcessingPlugin` |
| **Inputs** | Form Data |
| **Outputs** | Form Data |
| **Configuration Type** | N/A |

</details>

<details>
<summary><strong>Visitor Profile Plugins</strong></summary>

Process or modify visitor profiles when they are added or updated via the Visitor Registration endpoint.

| | |
|:---|:---|
| **Endpoint** | [/api/v2/cache/visit](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/cache/visit) |
| **Factory Base Class** | `RedPoint.Resonance.Web.Shared.Plugins.FilterableRealtimePluginFactoryBase` |
| **Plugin Interface** | `RedPoint.Resonance.Web.Shared.Plugins.IVisitorCachePlugin` |
| **Inputs** | Visitor Profile, Registration Request Details |
| **Outputs** | Visitor Profile |
| **Configuration Type** | `Visitor` |

</details>

<details>
<summary><strong>Geolocation Plugins</strong></summary>

Integrate external geolocation providers for use in realtime decisions. These only need a plugin class (no factory).

#### Geolocation

Looks up address, weather, forecasts, and geofence data using coordinates or a search string.

| | |
|:---|:---|
| **Endpoint** | [/api/v2/smart-assets/results](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/smart-assets/results) |
| **Plugin Interface** | `IGeolocationProvider` |
| **Inputs** | Long/Lat or Search String |
| **Outputs** | Address, Weather, Geofence Results |

#### IP to Geolocation

Resolves an IP address to longitude/latitude for geolocation-based decisions.

| | |
|:---|:---|
| **Endpoint** | [/api/v2/smart-assets/results](https://cdn.redpointglobal.com/api-docs/realtimeapidoc.html?scrollToPath=post-/api/v2/smart-assets/results) |
| **Plugin Interface** | `IGeoIPLookupPlugin` |
| **Inputs** | IP Address |
| **Outputs** | Long/Lat |

</details>

<details>
<summary><strong>Helm Chart Configuration</strong></summary>

### 1. Mount the plugin DLL

Upload your compiled DLL to shared storage (Azure Files, EFS, Filestore, etc.), create a PV and PVC, then reference it in your overrides:

```yaml
storage:
  persistentVolumeClaims:
    Plugins:
      enabled: true
      claimName: realtimeplugins
      mountPath: /app/plugins
```

The chart mounts this volume into the Realtime API container automatically. See the [Storage Guide](storage.md) for platform-specific PV/PVC setup.

### 2. Register plugins

Add the plugin configuration under `realtimeapi.customPlugins` in your overrides:

```yaml
realtimeapi:
  customPlugins:
    enabled: true
    list:
    - name: my-predecision-plugin
      factory:
        assembly: MyCompany.Plugins
        type: MyCompany.Plugins.PredecisionPluginFactory
      type:
        name: Predecision
        apiContextFilters:
          - my-context-filter
        apiContentFilterOperator: Include
      settings:
        - key: ApiEndpoint
          value: https://internal-api.example.com
        - key: Timeout
          value: "5000"
    - name: my-event-plugin
      factory:
        assembly: MyCompany.Plugins
        type: MyCompany.Plugins.EventPluginFactory
      type:
        name: Event
      settings:
        - key: LogLevel
          value: Verbose
```

**New deployment:** Include these blocks when generating your overrides via the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Generate** tab.

**Existing deployment:** Add the `storage.persistentVolumeClaims.Plugins` and `realtimeapi.customPlugins` blocks to your existing overrides file using the keys from the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Reference** tab, then run `helm upgrade`.

### 3. Apply

```bash
helm upgrade redpoint-rpi ./chart -f overrides.yaml -n redpoint-rpi
```

</details>

<details>
<summary><strong>Logging</strong></summary>

Use the `TraceLogHelper` class from `RedPoint.Resonance.Web.Shared.Logging` to log from your plugin:

```csharp
using RedPoint.Resonance.Web.Shared.Logging;

TraceLogHelper.SendTraceInformation(
    "Processing visitor profile",
    category: RealtimeLogCategory.Plugin
);

TraceLogHelper.SendTraceError(
    new Exception("Lookup failed"),
    "Geolocation provider returned an error",
    category: RealtimeLogCategory.Plugin
);
```

Plugin log output follows the Realtime API logging configuration. Set the `plugins` log level in your overrides to control verbosity:

```yaml
realtimeapi:
  logging:
    realtimeapi:
      plugins: Information    # Error, Warning, Information, Debug, Trace
```

</details>

---

## Example Project

The [RPI-Realtime-Plugin-Example](https://github.com/RedPointGlobal/RPI-Realtime-Plugin-Example) repository contains a working C# project with examples of each plugin type. Clone it as a starting point:

```bash
git clone https://github.com/RedPointGlobal/RPI-Realtime-Plugin-Example.git
```

Build with .NET 9, reference the `RedPoint.Web.Shared` NuGet package, and deploy the DLL to your plugins volume.

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
