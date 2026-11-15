FROM public.ecr.aws/datadog/lambda-extension:101 AS datadog-extension

FROM public.ecr.aws/lambda/python:3.13

# Datadog Lambda extension: ships logs, metrics, traces and LLM Observability data.
COPY --from=datadog-extension /opt/. /opt/

# boto3 ships with the Lambda base image; Datadog libraries are the only extra dependencies.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt --target "${LAMBDA_TASK_ROOT}"

COPY handler.py index.html ${LAMBDA_TASK_ROOT}/

# Datadog wrapper runs DD_LAMBDA_HANDLER (handler.lambda_handler) with tracing applied.
CMD ["datadog_lambda.handler.handler"]
