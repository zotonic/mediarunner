{% if m.acl.is_admin and not m.acl.is_read_only %}
    {% wire id=#delete type="submit" postback={consumer_delete_confirm id=consumer.id} delegate=`mediarunner` %}
    <form id="{{ #delete }}" method="post" action="postback">
        <p><strong>{{ consumer.description|escape }}</strong></p>
        <p>{_ Delete this consumer and revoke all its OAuth2 keys? Its dedicated user is also removed unless another OAuth2 app or key uses it. _}</p>
        <p>{_ Existing jobs and cached files remain until their normal cleanup. This cannot be undone. _}</p>
        <div class="modal-footer">
            {% button class="btn btn-default" text=_"Cancel" action={dialog_close} %}
            {% button class="btn btn-danger" type="submit" text=_"Delete consumer" %}
        </div>
    </form>
{% endif %}
