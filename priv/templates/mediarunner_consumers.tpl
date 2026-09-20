{% extends "mediarunner_dashboard.tpl" %}
{% block title %}{_ Consumers _}{% endblock %}
{% block js_extra %}{% endblock %}
{% block content %}
{% if m.acl.is_admin %}
<main class="mr-dashboard">
    <header class="mr-heading">
        <div><h1>{_ Consumers _}</h1><p>{_ Websites using this media runner. Each consumer has its own user and media cache. _}</p></div>
        {% if not m.acl.is_read_only %}
            {% button class="btn btn-primary" text=_"Add website / consumer" postback=`consumer_new` delegate=`mediarunner` %}
        {% endif %}
    </header>
    <p>{_ Job totals include retained history and continue accumulating after job cleanup. Processing time is elapsed execution time, excluding cache hits. Queue and cache figures show current usage. _}</p>
    <section class="mr-panel">
        <div class="mr-table-scroll">
            <table>
                <thead><tr><th>{_ Name _}</th><th>{_ User _}</th><th>{_ Status _}</th><th>{_ Jobs _}</th><th>{_ Queue now _}</th><th>{_ Cache now _}</th><th>{_ Actions _}</th></tr></thead>
                <tbody>
                    {% for consumer in m.mediarunner_consumer.list %}
                        <tr>
                            <td>{{ consumer.description|escape }}</td>
                            <td>{{ consumer.user_id|escape }}</td>
                            <td>{% if consumer.is_enabled %}{_ Enabled _}{% else %}{_ Disabled _}{% endif %}</td>
                            {% with consumer.statistics as stats %}
                                <td>
                                    <strong>{{ stats.submitted|default:0 }}</strong> {_ submitted _}
                                    <details>
                                        <summary>{_ Statistics _}</summary>
                                        <dl>
                                            <dt>{_ Completed _}</dt><dd>{{ stats.completed|default:0 }}</dd>
                                            <dt>{_ Failed _}</dt><dd>{{ stats.failed|default:0 }}</dd>
                                            <dt>{_ Result-cache hits _}</dt><dd>{{ stats.cache_hits|default:0 }}</dd>
                                            <dt>{_ Processing time (seconds) _}</dt><dd>{{ stats.processing_seconds|default:0 }}</dd>
                                            <dt>{_ Failed or expired callbacks _}</dt><dd>{{ stats.callback_failures|default:0 }}</dd>
                                        </dl>
                                    </details>
                                </td>
                                <td>{{ stats.queued|default:0 }} {_ waiting _}<br>{{ stats.running|default:0 }} {_ running _}<br>{{ stats.callbacks_pending|default:0 }} {_ callbacks pending _}</td>
                                <td>{{ stats.cached_bytes|default:0|filesizeformat }}<br>{{ stats.cached_files|default:0 }} {_ files _}</td>
                            {% endwith %}
                            <td>{% if not m.acl.is_read_only %}
                                {% button class="btn btn-default btn-sm" text=_"Update" postback={consumer_edit id=consumer.id} delegate=`mediarunner` %}
                                {% button class="btn btn-danger btn-sm" text=_"Delete" postback={consumer_delete id=consumer.id} delegate=`mediarunner` %}
                            {% endif %}</td>
                        </tr>
                    {% empty %}
                        <tr><td colspan="7">{_ No consumers yet. Add a website to create its first OAuth2 key. _}</td></tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>
    </section>
</main>
{% endif %}
{% endblock %}
