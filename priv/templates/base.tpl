{% overrules %}

{% block html_head_extra %}
    {% inherit %}
    {% lib "css/logon.css" %}
{% endblock %}

{# Keep site styles loaded when logon.tpl overrides html_head_extra. #}
{% block _html_head %}
    {% inherit %}
    {% lib "css/mediarunner.css" %}
{% endblock %}
